import AppKit

// ---------------------------------------------------------------------------
// Status model + menu bar icon drawing.
//
// Kept in its own file so tools/render-icons.swift can compile the exact same
// drawing code and dump a preview sheet.
// ---------------------------------------------------------------------------

enum Status: String {
    case working, waiting, done, error, idle

    /// Higher wins when several sessions are active at once.
    var severity: Int {
        switch self {
        case .error: return 4
        case .waiting: return 3
        case .working: return 2
        case .done: return 1
        case .idle: return 0
        }
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Waiting for you"
        case .done: return "Done"
        case .error: return "Error"
        case .idle: return "No active sessions"
        }
    }

    var color: NSColor {
        switch self {
        case .working: return NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1)
        case .waiting: return NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)
        case .done: return NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
        case .error: return NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1)
        case .idle: return NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)
        }
    }
}

struct LastError: Decodable {
    let tool: String?
    let message: String?
    let at: Double?
}

struct SessionRecord: Decodable {
    let sessionId: String?
    let status: String?
    let cwd: String?
    let project: String?
    let pid: Int?
    let background: Bool?
    let startedAt: Double?
    let updatedAt: Double?
    let turnStartedAt: Double?
    let detail: String?
    let tool: String?
    let waitingReason: String?
    let consecutiveFailures: Int?
    let errorsTotal: Int?
    let toolCount: Int?
    let lastError: LastError?
    let lastMessage: String?

    var state: Status { Status(rawValue: status ?? "idle") ?? .idle }
    var isBackground: Bool { background ?? false }
    var name: String { project ?? cwd.map { ($0 as NSString).lastPathComponent } ?? "claude" }
    var stamp: Double { updatedAt ?? 0 }
    var hasFailures: Bool { (consecutiveFailures ?? 0) > 0 }

    var isAlive: Bool {
        guard let pid = pid, pid > 1 else { return true }
        // kill(pid, 0) succeeds for a live process; EPERM means it exists but
        // belongs to someone else, which still counts as alive.
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}

/// How many of each event Claude Code has actually sent this build, and whether
/// it knew what to do with them. Everything this app understands about the hook
/// protocol was learned by observation, so a release that renames or adds an
/// event needs somewhere to become visible rather than just quietly changing
/// what the icon does.
struct EventTally: Decodable {
    let name: String?
    let count: Int?
    let lastSeen: Double?
    let unhandled: Bool?
}

struct StateFile: Decodable {
    let updatedAt: Double?
    let sessions: [String: SessionRecord]
    let events: [String: EventTally]?
}

/// Names Claude Code sent that this build has no handling for, most recent
/// first. Empty in the normal case, which is why it earns a menu row when it
/// is not.
func unhandledEvents(_ file: StateFile) -> [String] {
    return (file.events ?? [:]).values
        .filter { $0.unhandled == true }
        .sorted { ($0.lastSeen ?? 0) > ($1.lastSeen ?? 0) }
        .compactMap { $0.name }
}

// ---------------------------------------------------------------------------
// Plan usage limits
//
// Claude Code publishes the account's rate-limit windows in exactly one local
// place: the JSON it hands to the `statusLine` command. No hook event carries
// them. `hook.py --statusline` folds that into limits.json; this reads it.
//
// Two windows and no more - seven_day_opus, model_scoped and the rest live only
// in the SDK's get_usage response, which is a different, undocumented shape.
// ---------------------------------------------------------------------------

struct LimitWindow: Decodable {
    let usedPercentage: Double?
    let resetsAt: Double?
    /// When a Claude Code session last reported this number, which is not the
    /// same as when it was true: see `limitStaleAfter`.
    let capturedAt: Double?

    var percent: Double { max(0, min(100, usedPercentage ?? 0)) }
    func isLive(_ now: Double) -> Bool { (resetsAt ?? 0) > now && usedPercentage != nil }
}

struct LimitWindows: Decodable {
    let fiveHour: LimitWindow?
    let sevenDay: LimitWindow?
}

struct LimitsFile: Decodable {
    let updatedAt: Double?
    let seenAt: Double?        // last status line run, whatever it carried
    let rateLimitsSeen: Bool?  // has a payload ever carried rate_limits
    let windows: LimitWindows?
}

enum LimitKind: CaseIterable {
    case session, week

    var key: String {
        switch self {
        case .session: return "five_hour"
        case .week: return "seven_day"
        }
    }

    var label: String {
        switch self {
        case .session: return "Session limit (5h)"
        case .week: return "Weekly limit (7d)"
        }
    }

    func window(_ file: LimitsFile) -> LimitWindow? {
        switch self {
        case .session: return file.windows?.fiveHour
        case .week: return file.windows?.sevenDay
        }
    }
}

/// After this long without a fresh reading the number gets an "as of" marker.
/// It has to: the status line only runs while an interactive terminal is on
/// screen, so a value can be hours old - and a `claude -p` job can burn through
/// the same quota all afternoon without ever moving it.
let limitStaleAfter: Double = 10 * 60

/// The writer touches limits.json at least once a minute while a status line is
/// running, so nothing for this long means nothing is running it.
let limitStalledAfter: Double = 30 * 60

func resetsInText(_ seconds: Double) -> String {
    // Everything is derived from minutes-rounded-up, so the units stay
    // consistent across the boundaries: 59m 30s reads "1h", not "60m" (a unit
    // nothing else here produces) and not "0h 59m".
    let minutes = max(1, (max(0, Int(seconds.rounded())) + 59) / 60)
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 24 * 60 {
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
    let d = minutes / (24 * 60), h = (minutes % (24 * 60)) / 60
    return h == 0 ? "\(d)d" : "\(d)d \(h)h"
}

/// One rendered row, whichever source it came from.
struct LimitRow {
    let label: String
    let percent: Double
    let resetsAt: Double
    let capturedAt: Double
    /// Second-hand rows state their age even when recent, because "recent" for
    /// them means the last time you happened to open /usage.
    let alwaysShowAge: Bool

    var percentText: String { "\(Int(percent.rounded()))%" }

    func detail(now: Double) -> String {
        var parts: [String] = []
        if resetsAt > now { parts.append("resets in " + resetsInText(resetsAt - now)) }
        if capturedAt > 0, alwaysShowAge || now - capturedAt > limitStaleAfter {
            parts.append("as of " + shortDuration(now - capturedAt) + " ago")
        }
        return parts.joined(separator: " · ")
    }
}

func limitRow(_ kind: LimitKind, _ window: LimitWindow) -> LimitRow {
    return LimitRow(label: kind.label, percent: window.percent,
                    resetsAt: window.resetsAt ?? 0, capturedAt: window.capturedAt ?? 0,
                    alwaysShowAge: false)
}

// ---------------------------------------------------------------------------
// Per-model weekly windows
//
// The status line payload carries only the two account-wide windows. Per-model
// ones - Fable, Opus, Sonnet - exist solely in the /api/oauth/usage response,
// which Claude Code caches into ~/.claude.json as `cachedUsageUtilization`
// every time you open /usage. Reading that file costs nothing and needs no
// credentials; calling the endpoint ourselves would need the full login token
// and could rotate Claude Code out of its own session.
//
// The catch is the refresh: only /usage writes it. These rows are second-hand
// by nature, so they always carry their age and disappear once it is absurd.
// ---------------------------------------------------------------------------

/// Past this, a cached percentage says more about when you last opened /usage
/// than about your account.
let modelLimitMaxAge: Double = 24 * 3600

/// The cache stores ISO 8601 with microseconds. ISO8601DateFormatter rejects
/// that either way round - its fractional-seconds option insists the fraction
/// be there, the plain option insists it not be - so drop the fraction and one
/// setting parses every shape the server sends.
func parseTimestamp(_ text: String) -> Double? {
    let trimmed = text.replacingOccurrences(of: "\\.\\d+", with: "",
                                            options: .regularExpression)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: trimmed)?.timeIntervalSince1970
}

/// resets_at is an ISO string here, unlike the status line's epoch seconds -
/// and Claude Code's own projection defensively accepts a number too.
struct FlexibleDate: Decodable {
    let time: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { time = nil }
        else if let seconds = try? container.decode(Double.self) { time = seconds }
        else if let text = try? container.decode(String.self) { time = parseTimestamp(text) }
        else { time = nil }
    }
}

struct CachedWindow: Decodable {
    let utilization: Double?
    let resetsAt: FlexibleDate?
}

struct CachedModelLimit: Decodable {
    let kind: String?
    let percent: Double?
    let resetsAt: FlexibleDate?
    let scope: Scope?

    struct Scope: Decodable {
        let model: Model?
        struct Model: Decodable { let displayName: String? }
    }
}

struct CachedUtilization: Decodable {
    let sevenDayOpus: CachedWindow?
    let sevenDaySonnet: CachedWindow?
    let limits: [CachedModelLimit]?
}

struct UsageCache: Decodable {
    let fetchedAtMs: Double?
    let utilization: CachedUtilization?
}

/// ~/.claude.json, of which exactly one key is any of our business.
struct ClaudeConfigFile: Decodable {
    let cachedUsageUtilization: UsageCache?
}

func modelLimitRows(_ cache: UsageCache, now: Double) -> [LimitRow] {
    let captured = (cache.fetchedAtMs ?? 0) / 1000
    guard captured > 0, now - captured < modelLimitMaxAge,
          let usage = cache.utilization else { return [] }

    var rows: [String: LimitRow] = [:]
    func add(_ name: String?, _ percent: Double?, _ resets: Double?) {
        guard let name = name, !name.isEmpty, let percent = percent,
              let resets = resets, resets > now else { return }
        // No reset time means the window never opened - that model has not been
        // used this week - and an eternal 0% bar is worse than no row at all.
        rows[name.lowercased()] = LimitRow(label: name + " (7d)", percent: percent,
                                           resetsAt: resets, capturedAt: captured,
                                           alwaysShowAge: true)
    }
    // Server-named rows win; the fixed keys only fill gaps they leave.
    for row in usage.limits ?? [] where row.kind == "weekly_scoped" {
        add(row.scope?.model?.displayName, row.percent, row.resetsAt?.time)
    }
    for (name, window) in [("Opus", usage.sevenDayOpus), ("Sonnet", usage.sevenDaySonnet)] {
        if rows[name.lowercased()] == nil {
            add(name, window?.utilization, window?.resetsAt?.time)
        }
    }
    return rows.values.sorted { $0.label < $1.label }
}

/// Why there is nothing to show, short enough for a menu row plus the long
/// version for its tooltip. Deliberately does not try to diagnose the account
/// type: nothing in the payload identifies it, and guessing from elapsed time
/// told ordinary subscribers they were on Bedrock for the crime of leaving a
/// terminal open before their first message.
func limitPlaceholder(_ file: LimitsFile, now: Double, sessionsLive: Bool)
        -> (text: String, detail: String) {
    if now - (file.seenAt ?? 0) > limitStalledAfter {
        return sessionsLive
            ? ("not updating", "Nothing has run the status line for a while. Check the "
                             + "statusLine entry in ~/.claude/settings.json - Claude Code's own "
                             + "/statusline command replaces it.")
            : ("no Claude Code session running", "These only refresh while an interactive "
                             + "Claude Code terminal is open.")
    }
    if file.rateLimitsSeen == true {
        return ("window reset", "Waiting for the next request to report the new window.")
    }
    return ("no reading yet", "Claude Code publishes these only after an API response — and "
                            + "never for API-key, Bedrock or Vertex sessions, whose responses "
                            + "do not carry the rate-limit headers.")
}

func limitBarColor(_ percent: Double) -> NSColor {
    if percent >= 95 { return .systemRed }
    if percent >= 80 { return .systemOrange }
    return .controlAccentColor
}

let limitBarSize = NSSize(width: 58, height: 6)

/// Drawn, not typed. The menu font has no block-drawing glyphs, so a "████░░░░"
/// bar falls back to three different typefaces at three different widths and
/// shoves everything after it sideways every time the value changes.
func limitBarImage(percent: Double, size: NSSize = limitBarSize) -> NSImage {
    let fraction = max(0, min(1, percent / 100))
    let color = limitBarColor(percent)
    let image = NSImage(size: size, flipped: false) { rect in
        let radius = rect.height / 2
        // Resolved inside the handler on purpose: AppKit re-runs it once per
        // appearance and caches the result, so light and dark adapt for free.
        // A colour resolved outside is frozen at whichever appearance happened
        // to be current when the image was built.
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        if fraction > 0 {
            color.setFill()
            // A rounded cap degenerates below its own diameter, so clamp: 1%
            // should read as a dot, not a sliver.
            let width = max(rect.height, rect.width * CGFloat(fraction))
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: rect.height),
                         xRadius: radius, yRadius: radius).fill()
        }
        return true
    }
    // A template image is flattened to an alpha mask and tinted with the menu's
    // text colour, which would paint the bar black.
    image.isTemplate = false
    return image
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A finished session stops driving the menu bar colour after this long, so a
/// terminal left open overnight doesn't keep the icon green forever.
let doneFadeAfter: Double = 15 * 60

func shortDuration(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s < 60 { return "\(s)s" }
    if s < 3600 {
        let m = s / 60, r = s % 60
        return r == 0 ? "\(m)m" : "\(m)m \(r)s"
    }
    let h = s / 3600, m = (s % 3600) / 60
    return m == 0 ? "\(h)h" : "\(h)h \(m)m"
}

func agoText(_ stamp: Double) -> String {
    guard stamp > 0 else { return "" }
    return shortDuration(Date().timeIntervalSince1970 - stamp) + " ago"
}

func plural(_ n: Int, _ one: String, _ many: String) -> String {
    return n == 1 ? "\(n) \(one)" : "\(n) \(many)"
}

// ---------------------------------------------------------------------------
// Icon drawing
//
// Drawn by hand rather than with SF Symbols so the four states stay visually
// distinct at 18pt and the "working" ring can animate.
// ---------------------------------------------------------------------------

func statusImage(status: Status, badge: Bool, phase: Double) -> NSImage {
    let side: CGFloat = 18
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
        let center = NSPoint(x: side / 2, y: side / 2)
        let color = status.color

        switch status {
        case .working:
            let radius: CGFloat = 5.7
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.3
            color.withAlphaComponent(0.22).setStroke()
            track.stroke()

            let start = CGFloat(phase.truncatingRemainder(dividingBy: 1.0)) * 360
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start + 105)
            arc.lineWidth = 2.3
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()

        case .idle:
            let ring = NSBezierPath()
            ring.appendArc(withCenter: center, radius: 5.7, startAngle: 0, endAngle: 360)
            ring.lineWidth = 1.7
            color.withAlphaComponent(0.75).setStroke()
            ring.stroke()

        case .done, .waiting, .error:
            let disc = NSBezierPath(ovalIn: NSRect(x: 2.3, y: 2.3, width: side - 4.6, height: side - 4.6))
            color.setFill()
            disc.fill()
            NSColor.white.setFill()
            NSColor.white.setStroke()

            if status == .done {
                let check = NSBezierPath()
                check.move(to: NSPoint(x: 5.9, y: 9.2))
                check.line(to: NSPoint(x: 8.1, y: 6.9))
                check.line(to: NSPoint(x: 12.2, y: 11.8))
                check.lineWidth = 2.0
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.stroke()
            } else if status == .waiting {
                // pause bars: "paused, needs you"
                for x in [CGFloat(6.3), CGFloat(9.8)] {
                    NSBezierPath(roundedRect: NSRect(x: x, y: 5.8, width: 1.9, height: 6.4),
                                 xRadius: 0.9, yRadius: 0.9).fill()
                }
            } else {
                NSBezierPath(roundedRect: NSRect(x: 8.05, y: 7.6, width: 1.9, height: 5.0),
                             xRadius: 0.95, yRadius: 0.95).fill()
                NSBezierPath(ovalIn: NSRect(x: 7.85, y: 4.8, width: 2.3, height: 2.3)).fill()
            }
        }

        if badge {
            // a tool call failed during the current turn
            let dot = NSRect(x: side - 6.4, y: 0.6, width: 5.4, height: 5.4)
            // Punch a transparent gap so the dot reads cleanly against the ring
            // behind it on both light and dark menu bars.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.1, dy: -1.1)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            Status.error.color.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        return true
    }
    image.isTemplate = false
    return image
}

// ---------------------------------------------------------------------------
// Menu text
//
// Pure so tools/menu-text can print exactly what a user would read.
// ---------------------------------------------------------------------------

func sessionLines(_ record: SessionRecord, effective: Status) -> (title: String, subtitle: String) {
    let shown = effective == .idle ? record.state : effective
    let title = "\(record.name) — \(shown.label)"

    var parts: [String] = []
    switch record.state {
    case .waiting:
        if let reason = record.waitingReason, !reason.isEmpty { parts.append(reason) }
        if let detail = record.detail, !detail.isEmpty { parts.append(detail) }
    case .error:
        if let err = record.lastError {
            let tool = err.tool ?? "tool"
            let message = (err.message ?? "").replacingOccurrences(of: "\n", with: " · ")
            parts.append("\(tool): \(message)")
        } else if let detail = record.detail, !detail.isEmpty {
            parts.append(detail)
        }
    case .working:
        if let tool = record.tool, !tool.isEmpty {
            let detail = record.detail ?? ""
            parts.append(detail.isEmpty ? tool : "\(tool): \(detail)")
        } else if let detail = record.detail, !detail.isEmpty {
            parts.append(detail)
        }
        if let started = record.turnStartedAt, started > 0 {
            parts.append(shortDuration(Date().timeIntervalSince1970 - started))
        }
        if let count = record.toolCount, count > 0 {
            parts.append(plural(count, "tool call", "tool calls"))
        }
        if record.hasFailures, let err = record.lastError {
            parts.append("⚠︎ \(err.tool ?? "error")")
        }
    default:
        if let message = record.lastMessage, !message.isEmpty { parts.append("\u{201C}\(message)\u{201D}") }
        parts.append(agoText(record.stamp))
    }

    return (title, parts.filter { !$0.isEmpty }.joined(separator: " · "))
}
