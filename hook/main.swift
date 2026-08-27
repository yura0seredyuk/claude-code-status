// Claude Code -> menu bar status bridge.
//
// Reads one hook event on stdin and folds it into
// ~/.claude/statuslamp/state.json, which the Statuslamp menu bar app
// renders. Run with --statusline it acts as a `statusLine` command instead,
// folding the account's plan usage windows into limits.json.
//
// A Swift port of what was hook/statuslamp-hook.py, kept deliberately close
// to it - same file formats, same locking, same semantics - for two reasons:
// end users no longer need /usr/bin/python3 (which on a Mac without the Xcode
// Command Line Tools pops an install dialog), and this runs on every single
// tool call, where an interpreter start is most of the cost.
//
// It must be fast, silent and unable to break the session: it never writes to
// stdout in hook mode (UserPromptSubmit stdout is injected into Claude's
// context) and always exits 0.

import Darwin
import Foundation

/// $HOME first, exactly like Python's expanduser. NSHomeDirectory() reads the
/// passwd entry and ignores the environment, which silently sends the hook at
/// the real home no matter what it was pointed at - worth getting right for
/// testability alone, but it also diverges from the installer that registered
/// it and from every other tool in this repo.
let home: String = {
    if let value = ProcessInfo.processInfo.environment["HOME"], !value.isEmpty { return value }
    return NSHomeDirectory()
}()
let base = home + "/.claude/statuslamp"
let statePath = base + "/state.json"
let lockPath = base + "/state.lock"
let limitsPath = base + "/limits.json"
let limitsLockPath = base + "/limits.lock"
let logPath = base + "/hook.log"

let stateVersion = 1
let maxSessions = 60
let sessionTTL: Double = 24 * 3600   // forget sessions untouched for a day
let lockTimeout: Double = 1.5        // never stall a tool call for longer than this

let limitsVersion = 1
// The status line sits in front of an on-screen UI element and fires several
// times a second while a turn streams, so this path is stingier than the hook
// one: never queue long behind another session, never rewrite an unchanged file.
let limitsLockTimeout: Double = 0.3
let limitsHeartbeat: Double = 60
// The only two windows the status line payload carries. seven_day_opus,
// model_scoped and the rest exist solely in the SDK's get_usage response.
let limitWindows = [("five_hour", "5h"), ("seven_day", "7d")]

func now() -> Double { Date().timeIntervalSince1970 }

func debug(_ message: String) {
    guard ProcessInfo.processInfo.environment["CLAUDE_STATUS_DEBUG"] == "1" else { return }
    let stamp = DateFormatter()
    stamp.dateFormat = "HH:mm:ss"
    let line = stamp.string(from: Date()) + " " + message + "\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: logPath))
    }
}

// ---------------------------------------------------------------------------
// lenient JSON
// ---------------------------------------------------------------------------

/// Claude Code embeds raw newlines inside string values - the `error` field of
/// PostToolUseFailure carries "Exit code 9\noops" as literal bytes - which
/// strict JSON forbids and JSONSerialization rejects outright. Python's json
/// module has `strict=False` for exactly this; here the offending control
/// characters have to be escaped before the parser sees them.
func lenientJSONObject(_ data: Data) -> Any? {
    if let value = try? JSONSerialization.jsonObject(with: data) { return value }

    var out = [UInt8]()
    out.reserveCapacity(data.count + 32)
    var inString = false
    var escaped = false
    for byte in data {
        if escaped {
            out.append(byte)
            escaped = false
            continue
        }
        if byte == 0x5C {                     // backslash
            out.append(byte)
            escaped = inString
            continue
        }
        if byte == 0x22 {                     // quote
            inString.toggle()
            out.append(byte)
            continue
        }
        if inString && byte < 0x20 {
            switch byte {
            case 0x0A: out.append(contentsOf: Array(#"\n"#.utf8))
            case 0x0D: out.append(contentsOf: Array(#"\r"#.utf8))
            case 0x09: out.append(contentsOf: Array(#"\t"#.utf8))
            default:   out.append(contentsOf: Array(String(format: #"\u%04x"#, Int(byte)).utf8))
            }
            continue
        }
        out.append(byte)
    }
    return try? JSONSerialization.jsonObject(with: Data(out))
}

func loadJSONObject(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return lenientJSONObject(data) as? [String: Any]
}

// ---------------------------------------------------------------------------
// locking and atomic writes
// ---------------------------------------------------------------------------

/// Exclusive flock, or nil if someone else still holds it. Never waits longer
/// than `timeout`: no status file is worth stalling a session over.
func takeLock(_ path: String, _ timeout: Double) -> Int32? {
    let deadline = now() + timeout
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return nil }
    while true {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        if now() > deadline {
            close(fd)
            return nil
        }
        usleep(10_000)
    }
}

func releaseLock(_ fd: Int32) {
    flock(fd, LOCK_UN)
    close(fd)
}

/// Serialised with sorted keys so an unchanged state produces unchanged bytes -
/// the app's change detection keys on size and mtime.
func writeJSON(_ object: [String: Any], to path: String, fsync doFsync: Bool) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let tmp = "\(path).\(getpid()).tmp"
    let handle = FileManager.default.createFile(atPath: tmp, contents: nil)
    guard handle, let file = FileHandle(forWritingAtPath: tmp) else {
        throw NSError(domain: "hook", code: 1)
    }
    file.write(data)
    // F_FULLFSYNC is the one that actually reaches the platter; not every
    // filesystem implements it, so fall back rather than skip the flush.
    if doFsync, fcntl(file.fileDescriptor, F_FULLFSYNC) == -1 {
        _ = Darwin.fsync(file.fileDescriptor)
    }
    try? file.close()
    if rename(tmp, path) != 0 {
        unlink(tmp)
        throw NSError(domain: "hook", code: 2)
    }
}

// ---------------------------------------------------------------------------
// describing what Claude is doing right now
// ---------------------------------------------------------------------------

// StopFailure.error is an enum; show it in words rather than as a slug.
let apiErrors = [
    "rate_limit": "Rate limit",
    "overloaded": "Service overloaded",
    "authentication_failed": "Authentication failed",
    "oauth_org_not_allowed": "Organisation not allowed",
    "billing_error": "Billing problem",
    "invalid_request": "Invalid request",
    "model_not_found": "Model not found",
    "server_error": "Server error",
    "max_output_tokens": "Output limit exceeded",
    "unknown": "Unknown error",
]

func clip(_ text: String, _ limit: Int) -> String {
    let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    if collapsed.count <= limit { return collapsed }
    return String(collapsed.prefix(limit - 1)) + "…"
}

func describeTool(_ tool: String, _ input: Any?) -> String {
    let args = input as? [String: Any] ?? [:]
    func arg(_ names: String...) -> String? {
        for name in names {
            if let value = args[name] as? String, !value.isEmpty { return value }
        }
        return nil
    }
    switch tool {
    case "Bash":
        return clip(arg("command") ?? "", 90)
    case "Read", "Edit", "Write", "NotebookEdit":
        guard let path = arg("file_path", "notebook_path") else { return "" }
        return (path as NSString).lastPathComponent
    case "Grep", "Glob":
        return clip(arg("pattern") ?? "", 60)
    case "WebFetch", "WebSearch":
        return clip(arg("url", "query") ?? "", 60)
    case "Task", "Agent":
        return clip(arg("description", "subagent_type") ?? "", 60)
    case "Skill":
        return clip(arg("skill") ?? "", 40)
    default:
        return clip(arg("description") ?? "", 60)
    }
}

// ---------------------------------------------------------------------------
// state file
// ---------------------------------------------------------------------------

func blankState() -> [String: Any] {
    return ["version": stateVersion, "updated_at": now(), "sessions": [String: Any]()]
}

func loadState() -> [String: Any] {
    if let data = loadJSONObject(statePath), data["sessions"] is [String: Any] { return data }
    return blankState()
}

func pidAlive(_ pid: Int?) -> Bool {
    guard let pid = pid, pid > 0 else { return true }  // unknown pid: staleness will catch it
    // kill(pid, 0) succeeds for a live process; EPERM means it exists but
    // belongs to someone else, which still counts as alive.
    if kill(pid_t(pid), 0) == 0 { return true }
    return errno == EPERM
}

func prune(_ sessions: inout [String: Any], keeping keepID: String?) {
    let cutoff = now()
    for (sid, value) in sessions {
        if sid == keepID { continue }
        guard let record = value as? [String: Any] else {
            sessions.removeValue(forKey: sid)
            continue
        }
        let updated = record["updated_at"] as? Double ?? 0
        if cutoff - updated > sessionTTL || !pidAlive(record["pid"] as? Int) {
            sessions.removeValue(forKey: sid)
        }
    }
    if sessions.count > maxSessions {
        let ordered = sessions.sorted {
            (($0.value as? [String: Any])?["updated_at"] as? Double ?? 0)
                < (($1.value as? [String: Any])?["updated_at"] as? Double ?? 0)
        }
        for (sid, _) in ordered.prefix(sessions.count - maxSessions) where sid != keepID {
            sessions.removeValue(forKey: sid)
        }
    }
}

// The events this build knows how to fold into a status. Everything in that
// handling was established by watching Claude Code rather than from any
// documentation, so a release that renames an event, or sends a new one for a
// matcher we registered, would change what the icon does with nothing anywhere
// saying why. The tally below is the cheap insurance: it rides in the state
// file that is written on every event anyway, so it costs no extra write.
let knownEvents: Set<String> = [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PostToolUseFailure", "PermissionRequest", "PermissionDenied",
    "Notification", "Stop", "StopFailure", "SessionEnd",
]

let maxTalliedEvents = 40

func recordEvent(_ events: inout [String: Any], _ name: String) {
    guard !name.isEmpty else { return }
    let stamp = now()
    var entry = events[name] as? [String: Any] ?? [:]
    // Carried explicitly: the app decodes with convertFromSnakeCase, which
    // rewrites dictionary keys too, and an event named with an underscore would
    // otherwise be displayed under a name Claude Code never sent.
    entry["name"] = name
    entry["count"] = (entry["count"] as? Int ?? 0) + 1
    entry["last_seen"] = stamp
    if entry["first_seen"] == nil { entry["first_seen"] = stamp }
    if !knownEvents.contains(name) { entry["unhandled"] = true }
    events[name] = entry

    // Bounded, so a renamed-every-release event or a malformed payload cannot
    // grow the file without limit. The least recently seen go first.
    if events.count > maxTalliedEvents {
        let ordered = events.sorted {
            (($0.value as? [String: Any])?["last_seen"] as? Double ?? 0)
                < (($1.value as? [String: Any])?["last_seen"] as? Double ?? 0)
        }
        for (key, _) in ordered.prefix(events.count - maxTalliedEvents) where key != name {
            events.removeValue(forKey: key)
        }
    }
}

func saveState(_ state: [String: Any]) throws {
    var copy = state
    copy["version"] = stateVersion
    copy["updated_at"] = now()
    try writeJSON(copy, to: statePath, fsync: true)
}

// ---------------------------------------------------------------------------
// event -> state folding
// ---------------------------------------------------------------------------

// Non-interactive entrypoints: `claude -p` and SDK/MCP callers. These are the
// sessions worth hiding. CLAUDE_CODE_CHILD_SESSION cannot be used for this -
// some setups run the user's own terminal under an agent harness that sets it,
// which would hide the very sessions the indicator exists for.
let backgroundEntrypoints: Set<String> = ["sdk-cli", "sdk-py", "sdk-ts", "mcp"]

func isBackground() -> Bool {
    let env = ProcessInfo.processInfo.environment
    let entrypoint = env["CLAUDE_CODE_ENTRYPOINT"] ?? ""
    if !entrypoint.isEmpty { return backgroundEntrypoints.contains(entrypoint) }
    // Unknown entrypoint: fall back to the child flag, and prefer showing.
    return env["CLAUDE_CODE_CHILD_SESSION"] == "1"
}

func claudePID() -> Int {
    if let raw = ProcessInfo.processInfo.environment["CLAUDE_PID"], let pid = Int(raw), pid > 0 {
        return pid
    }
    return Int(getppid())
}

func newRecord(_ sid: String, _ event: [String: Any]) -> [String: Any] {
    let stamp = now()
    let cwd = (event["cwd"] as? String)
        ?? ProcessInfo.processInfo.environment["CLAUDE_PROJECT_DIR"] ?? ""
    let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
    let project = (trimmed as NSString).lastPathComponent
    return [
        "session_id": sid,
        "status": "idle",
        "cwd": cwd,
        "project": project.isEmpty ? (cwd.isEmpty ? "claude" : cwd) : project,
        "pid": claudePID(),
        "entrypoint": ProcessInfo.processInfo.environment["CLAUDE_CODE_ENTRYPOINT"] ?? "",
        "background": isBackground(),
        "started_at": stamp,
        "updated_at": stamp,
        "turn_started_at": stamp,
        "detail": "",
        "tool": "",
        "waiting_reason": "",
        "consecutive_failures": 0,
        "errors_total": 0,
        "tool_count": 0,
        "last_error": NSNull(),
        "last_event": "",
        "last_message": "",
    ]
}

/// Returns the session id the event touched, or nil if it was unusable.
/// `removed` is set when the session should drop off the list entirely.
func applyEvent(_ sessions: inout [String: Any], _ event: [String: Any])
        -> (sid: String?, removed: Bool) {
    let name = event["hook_event_name"] as? String ?? ""
    let sid = (event["session_id"] as? String)
        ?? ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"]
    guard let sid = sid, !sid.isEmpty else { return (nil, false) }

    var record = sessions[sid] as? [String: Any] ?? newRecord(sid, event)
    let stamp = now()
    record["updated_at"] = stamp
    record["last_event"] = name
    if let cwd = event["cwd"] as? String, !cwd.isEmpty {
        record["cwd"] = cwd
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let project = (trimmed as NSString).lastPathComponent
        record["project"] = project.isEmpty ? cwd : project
    }
    // A session that predates the app install has no pid yet.
    if (record["pid"] as? Int ?? 0) == 0 { record["pid"] = claudePID() }
    // Recomputed on every event so a record created before this rule existed,
    // or first seen through a subagent, corrects itself.
    record["background"] = isBackground()

    func intOf(_ key: String) -> Int { record[key] as? Int ?? 0 }

    switch name {
    case "SessionStart":
        // source is one of startup/resume/clear/compact/fork. "compact" fires
        // mid-turn on auto-compaction under the same session_id - it is not a
        // new session, so the running turn's status and counters must survive.
        if (event["source"] as? String) != "compact" {
            record["status"] = "idle"
            record["detail"] = ""
            record["consecutive_failures"] = 0
            record["errors_total"] = 0
        }

    case "UserPromptSubmit":
        record["status"] = "working"
        record["turn_started_at"] = stamp
        record["detail"] = clip(event["prompt"] as? String ?? "", 70)
        record["tool"] = ""
        record["waiting_reason"] = ""
        record["consecutive_failures"] = 0
        record["errors_total"] = 0
        record["tool_count"] = 0
        record["last_error"] = NSNull()
        record["last_message"] = ""

    case "PreToolUse":
        let tool = event["tool_name"] as? String ?? "tool"
        record["status"] = "working"
        record["tool"] = tool
        record["detail"] = describeTool(tool, event["tool_input"])
        record["waiting_reason"] = ""
        record["tool_count"] = intOf("tool_count") + 1

    case "PostToolUse":
        record["status"] = "working"
        record["waiting_reason"] = ""
        record["consecutive_failures"] = 0        // Claude recovered; stop badging

    case "PostToolUseFailure":
        let tool = event["tool_name"] as? String ?? "tool"
        if (event["is_interrupt"] as? Bool) == true {
            // user pressed Esc - not a failure worth alarming about
            record["status"] = "done"
            record["detail"] = "Interrupted"
            record["consecutive_failures"] = 0
        } else {
            record["status"] = "working"
            record["consecutive_failures"] = intOf("consecutive_failures") + 1
            record["errors_total"] = intOf("errors_total") + 1
            record["last_error"] = [
                "tool": tool,
                "message": clip(event["error"] as? String ?? "", 300),
                "at": stamp,
            ] as [String: Any]
        }
        record["waiting_reason"] = ""

    case "PermissionRequest":
        let tool = event["tool_name"] as? String ?? "tool"
        record["status"] = "waiting"
        record["waiting_reason"] = "Permission needed: \(tool)"
        let detail = describeTool(tool, event["tool_input"])
        record["detail"] = detail.isEmpty ? (record["detail"] as? String ?? "") : detail

    case "PermissionDenied":
        // A denial is the user's decision, not a failure - just forward progress.
        record["status"] = "working"
        record["waiting_reason"] = ""

    case "Notification":
        let message = clip(event["message"] as? String ?? "", 120)
        let kind = (event["notification_type"] as? String) ?? (event["type"] as? String) ?? ""
        let status = record["status"] as? String ?? ""
        if kind == "idle_prompt" {
            // Fires a minute after Claude goes quiet, including after a finished
            // turn - only treat it as a pause if Claude was mid-flight.
            if status == "working" {
                record["status"] = "waiting"
                record["waiting_reason"] = message.isEmpty ? "Waiting for you" : message
            }
        } else if ["permission_prompt", "agent_needs_input", "elicitation_dialog"].contains(kind) {
            record["status"] = "waiting"
            record["waiting_reason"] = message.isEmpty ? "Waiting for you" : message
        } else if kind.isEmpty && status == "working" {
            // Unknown/older builds: fall back to the conservative rule.
            record["status"] = "waiting"
            record["waiting_reason"] = message.isEmpty ? "Waiting for you" : message
        } else if !message.isEmpty {
            record["waiting_reason"] = message
        }

    case "StopFailure":
        // The turn died on an API/session error - rate limit, overload, auth.
        let kind = event["error"] as? String ?? ""
        let detail = clip(event["error_details"] as? String ?? "", 240)
        let label = apiErrors[kind] ?? (kind.isEmpty ? "API" : kind)
        record["status"] = "error"
        record["tool"] = ""
        record["waiting_reason"] = ""
        record["errors_total"] = intOf("errors_total") + 1
        record["last_error"] = ["tool": label, "message": detail, "at": stamp] as [String: Any]
        record["detail"] = apiErrors[kind] ?? (kind.isEmpty ? "API error" : kind)

    case "Stop":
        record["status"] = intOf("consecutive_failures") > 0 ? "error" : "done"
        record["tool"] = ""
        record["waiting_reason"] = ""
        let message = clip(event["last_assistant_message"] as? String ?? "", 120)
        record["last_message"] = message
        record["detail"] = message

    case "SessionEnd":
        sessions.removeValue(forKey: sid)
        return (sid, true)

    default:
        break
    }

    sessions[sid] = record
    return (sid, false)
}

// ---------------------------------------------------------------------------
// plan usage limits
//
// Claude Code puts the account's rate-limit windows in the JSON it hands to the
// `statusLine` command. That is the only local surface carrying them: no hook
// event has a usage field, and neither does the subagent status line, the OTel
// metrics or the injected environment.
// ---------------------------------------------------------------------------

struct Window {
    var usedPercentage: Double
    var resetsAt: Int
    var capturedAt: Double = 0
    var sessionID: String = ""

    var asJSON: [String: Any] {
        return ["used_percentage": usedPercentage, "resets_at": resetsAt,
                "captured_at": capturedAt, "session_id": sessionID]
    }

    /// What "unchanged" means for the write gate.
    var digest: String { "\((usedPercentage * 10).rounded() / 10)|\(resetsAt)" }
}

func blankLimits() -> [String: Any] {
    return [
        "version": limitsVersion,
        "updated_at": 0.0,
        "seen_at": 0.0,        // last status line run, whatever it carried
        "first_seen_at": 0.0,
        "last_seen_at": 0.0,   // last run that actually carried rate_limits
        "rate_limits_seen": false,
        "windows": [String: Any](),
    ]
}

func loadLimits() -> [String: Any] {
    guard let data = loadJSONObject(limitsPath), data["windows"] is [String: Any] else {
        return blankLimits()
    }
    var state = blankLimits()
    for (key, value) in data { state[key] = value }
    return state
}

func finiteNumber(_ value: Any?) -> Double? {
    if value is Bool { return nil }
    guard let number = value as? NSNumber else { return nil }
    let double = number.doubleValue
    return double.isFinite ? double : nil
}

func windowFrom(_ value: Any?) -> Window? {
    guard let dict = value as? [String: Any] else { return nil }
    guard let used = finiteNumber(dict["used_percentage"]),
          let resets = finiteNumber(dict["resets_at"]) else { return nil }
    return Window(usedPercentage: used, resetsAt: Int(resets),
                  capturedAt: finiteNumber(dict["captured_at"]) ?? 0,
                  sessionID: dict["session_id"] as? String ?? "")
}

/// `rate_limits` is absent for API-key, Bedrock and Vertex sessions, and for
/// every session until its first API response: the numbers ride in on
/// anthropic-ratelimit-unified-* response headers, and each Claude Code process
/// keeps its own copy fed only by its own requests.
func readWindows(_ payload: [String: Any], _ stamp: Double) -> [String: Window] {
    guard let limits = payload["rate_limits"] as? [String: Any] else { return [:] }
    var found: [String: Window] = [:]
    for (key, _) in limitWindows {
        guard let window = windowFrom(limits[key]) else { continue }
        // Claude Code drops a window the moment it resets, and a non-numeric
        // utilisation would arrive as null. Either way there is nothing to show.
        if Double(window.resetsAt) <= stamp { continue }
        found[key] = window
    }
    return found
}

/// Utilisation only climbs until the window resets, so within one window a lower
/// reading is an older session's stale view rather than a refund - shift-tabbing
/// in a terminal idle since morning re-fires its status line with this morning's
/// number. Taking the maximum kills that flicker.
///
/// Two *live* windows with different resets_at cannot be the same window,
/// though: a stale process reports the same fixed reset time, and an expired one
/// has already been filtered out. So a differing reset time means a new
/// generation or - after `/login` - a different account, and the fresh reading
/// wins in both directions.
/// Returns which reading won as well as the reading itself: the Python original
/// tested object identity here, and a value type cannot.
func pickWindow(stored: Window?, fresh: Window?) -> (window: Window, fromFresh: Bool)? {
    guard let fresh = fresh else {
        guard let stored = stored else { return nil }
        return (stored, false)
    }
    guard let stored = stored else { return (fresh, true) }
    if fresh.resetsAt != stored.resetsAt { return (fresh, true) }
    return fresh.usedPercentage >= stored.usedPercentage ? (fresh, true) : (stored, false)
}

/// Folds one status line payload into limits.json and returns what the app will
/// see, so the terminal prints the same thing the menu bar shows.
func mergeLimits(_ fresh: [String: Window], sessionID: String?, _ stamp: Double)
        -> [String: Window] {
    guard let fd = takeLock(limitsLockPath, limitsLockTimeout) else {
        debug("limits lock busy")
        return fresh
    }
    defer { releaseLock(fd) }

    var state = loadLimits()
    let stored = state["windows"] as? [String: Any] ?? [:]
    var merged: [String: Window] = [:]
    var changed = false

    for (key, _) in limitWindows {
        var before = windowFrom(stored[key])
        if let existing = before, Double(existing.resetsAt) <= stamp {
            before = nil                      // rolled over while nothing was watching
        }
        guard let pick = pickWindow(stored: before, fresh: fresh[key]) else {
            changed = changed || stored[key] != nil
            continue
        }
        // A missing window means "this process has not heard yet", never "the
        // limit is gone", so absence must not erase what we know. The timestamp
        // follows the reading that actually WON: a stale session re-reporting an
        // old number must not refresh a stamp it did not earn.
        var chosen = pick.window
        if pick.fromFresh {
            chosen.capturedAt = stamp
            chosen.sessionID = sessionID ?? ""
        } else {
            chosen.capturedAt = before?.capturedAt ?? 0
            chosen.sessionID = before?.sessionID ?? ""
        }
        merged[key] = chosen
        changed = changed || before?.digest != chosen.digest
    }

    var windowsJSON = [String: Any]()
    for (key, window) in merged { windowsJSON[key] = window.asJSON }
    state["windows"] = windowsJSON
    state["seen_at"] = stamp
    if (finiteNumber(state["first_seen_at"]) ?? 0) == 0 { state["first_seen_at"] = stamp }
    if !fresh.isEmpty {
        state["rate_limits_seen"] = true
        state["last_seen_at"] = stamp
    }

    // The status line fires several times a second while a turn streams and
    // these numbers move a percent every few minutes, so write only when
    // something moved - plus a slow heartbeat, so "as of" stays honest.
    if changed || stamp - (finiteNumber(state["updated_at"]) ?? 0) >= limitsHeartbeat {
        state["version"] = limitsVersion
        state["updated_at"] = stamp
        // No fsync, unlike the state file: this is a cache of a number the next
        // status line run reproduces, and fsync has no business on a UI path.
        do { try writeJSON(state, to: limitsPath, fsync: false) }
        catch { debug("limits write failed") }
    }
    return merged
}

func statuslineText(_ windows: [String: Window]) -> String {
    var parts: [String] = []
    for (key, label) in limitWindows {
        if let window = windows[key] {
            parts.append("\(label) \(Int(window.usedPercentage.rounded()))%")
        }
    }
    return parts.joined(separator: " · ")
}

/// --statusline mode. stdout IS the terminal's status line here, so this is the
/// one path that prints - and it still has to exit 0: any other exit code makes
/// Claude Code discard the output and blank the row.
func statuslineMain(_ raw: Data) {
    var payload = [String: Any]()
    if !raw.isEmpty, let parsed = lenientJSONObject(raw) as? [String: Any] { payload = parsed }

    let stamp = now()
    var windows = readWindows(payload, stamp)
    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    windows = mergeLimits(windows, sessionID: payload["session_id"] as? String, stamp)

    let text = statuslineText(windows)
    if !text.isEmpty, let data = (text + "\n").data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
}

// ---------------------------------------------------------------------------

func hookMain(_ raw: Data) {
    guard !raw.isEmpty, let event = lenientJSONObject(raw) as? [String: Any] else {
        debug("parse failed")
        return
    }
    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)

    guard let fd = takeLock(lockPath, lockTimeout) else {
        debug("lock timeout for \(event["hook_event_name"] as? String ?? "?")")
        return
    }
    defer { releaseLock(fd) }

    var state = loadState()
    var sessions = state["sessions"] as? [String: Any] ?? [:]
    let result = applyEvent(&sessions, event)
    prune(&sessions, keeping: result.removed ? nil : result.sid)
    state["sessions"] = sessions

    var events = state["events"] as? [String: Any] ?? [:]
    recordEvent(&events, event["hook_event_name"] as? String ?? "")
    state["events"] = events
    do {
        try saveState(state)
        debug("\(event["hook_event_name"] as? String ?? "?") -> ok")
    } catch {
        debug("save failed")
    }
}

let raw = FileHandle.standardInput.readDataToEndOfFile()
if CommandLine.arguments.contains("--statusline") {
    statuslineMain(raw)
} else {
    hookMain(raw)
}
// Always succeed. A non-zero exit or stray stdout would disturb the session, and
// in --statusline mode it also makes Claude Code discard the output and blank
// the line.
exit(0)
