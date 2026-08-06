import AppKit
import Darwin
import UserNotifications

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

let launchAgentLabel = "com.claudestatus.agent"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
                         UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let defaults = UserDefaults.standard

    private let stateURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/claude-status/state.json")

    private var sessions: [SessionRecord] = []
    private var live: [SessionRecord] = []
    private var aggregate: Status = .idle
    private var badge = false
    private var phase: Double = 0
    private var lastSignature: String = ""
    private var lastRenderKey: String = ""

    /// Alerts fire per session, not per aggregate: two projects both asking for
    /// permission are two things you need to know about.
    private var lastStatus: [String: Status] = [:]
    /// NSSound must outlive play(); these are loaded once and kept.
    private var sounds: [Status: NSSound] = [:]

    private var pollTimer: Timer?
    private var animTimer: Timer?

    private var soundEnabled: Bool {
        get { defaults.object(forKey: "sound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sound") }
    }
    private var showBackground: Bool {
        get { defaults.bool(forKey: "showBackground") }
        set { defaults.set(newValue, forKey: "showBackground") }
    }
    private var dismissedBefore: Double {
        get { defaults.double(forKey: "dismissedBefore") }
        set { defaults.set(newValue, forKey: "dismissedBefore") }
    }
    private var notificationsEnabled: Bool {
        get { defaults.object(forKey: "notifications") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notifications") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading

        sounds[.waiting] = NSSound(named: "Funk")
        sounds[.error] = NSSound(named: "Basso")
        sounds[.done] = NSSound(named: "Glass")

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { _, _ in }

        reload(force: true)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.reload(force: false)
        }
        // Lets macOS coalesce the wakeup with other timers instead of waking
        // the CPU on its own schedule.
        pollTimer?.tolerance = 0.2
    }

    /// The spinner timer only exists while something is actually spinning -
    /// an idle menu bar app should not wake the CPU ten times a second.
    private func updateAnimation() {
        if aggregate == .working {
            guard animTimer == nil else { return }
            animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) {
                [weak self] _ in
                guard let self = self else { return }
                self.phase += 0.055
                self.renderIcon()
            }
        } else {
            animTimer?.invalidate()
            animTimer = nil
        }
    }

    // MARK: state

    /// Cheap change detection: only re-parse when the file actually moved.
    private func signature() -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: stateURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)|\(mtime)"
    }

    private func reload(force: Bool) {
        let sig = signature()
        // Even without a file change, `done` fades and durations tick along.
        let needsRefresh = force || sig != lastSignature
        lastSignature = sig

        if needsRefresh {
            sessions = readSessions()
        }
        // Re-checked every poll, not only when the file changes: a session that
        // dies stops writing, so its record would otherwise drive the icon
        // forever - an orange "waiting" for a terminal that is already closed.
        live = sessions.filter { $0.isAlive }
        detectTransitions()
        recomputeAggregate()
        renderIcon()
    }

    private func readSessions() -> [SessionRecord] {
        guard let data = try? Data(contentsOf: stateURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let file = try? decoder.decode(StateFile.self, from: data) else { return [] }
        return file.sessions.values.sorted { $0.stamp > $1.stamp }
    }

    private var visibleSessions: [SessionRecord] {
        showBackground ? live : live.filter { !$0.isBackground }
    }

    private func effectiveStatus(_ record: SessionRecord) -> Status {
        let state = record.state
        // "Clear finished" only silences finished sessions. A working
        // session can sit on one long tool call with an older stamp, and must
        // not be hidden by it.
        if state == .done || state == .error {
            if record.stamp <= dismissedBefore { return .idle }
            if state == .done, Date().timeIntervalSince1970 - record.stamp > doneFadeAfter {
                return .idle
            }
        }
        return state
    }

    private func recomputeAggregate() {
        var best: Status = .idle
        var anyBadge = false
        for record in visibleSessions {
            let state = effectiveStatus(record)
            if state.severity > best.severity { best = state }
            if state == .working && record.hasFailures { anyBadge = true }
        }
        badge = anyBadge

        if best != aggregate {
            aggregate = best
            updateAnimation()
        }
    }

    // MARK: alerts

    private func detectTransitions() {
        var current: [String: Status] = [:]
        for record in visibleSessions {
            guard let id = record.sessionId else { continue }
            current[id] = record.state
            // Only a *change* alerts. A session first seen mid-life - because
            // the app just launched, or the user unhid background sessions -
            // must not fire a banner for a state it has been in all along.
            if let previous = lastStatus[id], previous != record.state {
                alert(record, record.state)
            }
        }
        lastStatus = current
    }

    private func alert(_ record: SessionRecord, _ status: Status) {
        switch status {
        case .waiting, .error, .done: break
        default: return
        }
        if soundEnabled { sounds[status]?.play() }
        if notificationsEnabled { postNotification(record, status) }
    }

    private func postNotification(_ record: SessionRecord, _ status: Status) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let lines = sessionLines(record, effective: status)
        let content = UNMutableNotificationContent()
        content.title = lines.title
        content.body = lines.subtitle
        // Silent on purpose: "Sound alerts" is a separate switch, so turning one
        // off must not leave the other still making noise.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Shows banners even though an accessory app is never the active one.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .list])
    }

    private func renderIcon() {
        guard let button = statusItem.button else { return }

        let active = visibleSessions.filter { effectiveStatus($0) != .idle }.count
        // Redrawing the icon costs real CPU, and reload() runs twice a second
        // forever. Only redraw when something visible actually changed - while
        // spinning, that means once per animation step.
        let step = aggregate == .working ? Int(phase * 20) : 0
        let key = "\(aggregate.rawValue)|\(badge)|\(active)|\(step)"
        guard key != lastRenderKey else { return }
        lastRenderKey = key

        button.image = statusImage(status: aggregate, badge: badge, phase: phase)

        if active > 1 {
            button.attributedTitle = NSAttributedString(
                string: " \(active)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                ])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
        button.toolTip = "Claude Code — \(aggregate.label)"
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        reload(force: true)
        menu.removeAllItems()

        let header = NSMenuItem(title: "Claude Code — \(aggregate.label)", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(
            string: "Claude Code — \(aggregate.label)",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        menu.addItem(header)
        menu.addItem(.separator())

        let list = visibleSessions
        if list.isEmpty {
            let empty = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for record in list {
                menu.addItem(sessionItem(record))
            }
        }

        menu.addItem(.separator())
        menu.addItem(toggle("Sound alerts", on: soundEnabled, action: #selector(toggleSound)))
        menu.addItem(toggle("Notifications", on: notificationsEnabled, action: #selector(toggleNotifications)))
        menu.addItem(toggle("Show background sessions", on: showBackground, action: #selector(toggleBackground)))
        menu.addItem(toggle("Open at login", on: launchAtLoginEnabled(), action: #selector(toggleLaunchAtLogin)))
        menu.addItem(.separator())
        menu.addItem(item("Test alert", action: #selector(testAlert)))
        menu.addItem(item("Clear finished", action: #selector(dismissFinished)))
        menu.addItem(item("Reveal state.json in Finder", action: #selector(revealState)))
        menu.addItem(.separator())
        menu.addItem(item("Quit", action: #selector(quit), key: "q"))
    }

    private func sessionItem(_ record: SessionRecord) -> NSMenuItem {
        let state = effectiveStatus(record)
        let lines = sessionLines(record, effective: state)
        let title = NSMutableAttributedString(
            string: lines.title,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])

        let subtitle = lines.subtitle
        if !subtitle.isEmpty {
            title.append(NSAttributedString(
                string: "\n" + subtitle,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
        }

        let menuItem = NSMenuItem(title: record.name, action: #selector(openSession(_:)), keyEquivalent: "")
        menuItem.attributedTitle = title
        menuItem.target = self
        // Carry the path itself: an index would point at the wrong session if
        // the list shifted between opening the menu and clicking.
        menuItem.representedObject = record.cwd
        menuItem.image = statusImage(status: state == .idle ? record.state : state, badge: false, phase: 0)
        menuItem.toolTip = record.cwd
        return menuItem
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    private func toggle(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let menuItem = item(title, action: action)
        menuItem.state = on ? .on : .off
        return menuItem
    }

    // MARK: actions

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func toggleSound() { soundEnabled.toggle() }
    @objc private func toggleNotifications() { notificationsEnabled.toggle() }

    /// So "I hear nothing" can be answered without waiting for Claude to stop.
    @objc private func testAlert() {
        if soundEnabled { sounds[.done]?.play() }
        guard notificationsEnabled, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Claude Status — Test alert"
        content.body = "Notifications and sound are working."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    @objc private func toggleBackground() { showBackground.toggle(); reload(force: true) }

    @objc private func dismissFinished() {
        dismissedBefore = live
            .filter { $0.state == .done || $0.state == .error }
            .map { $0.stamp }
            .max() ?? Date().timeIntervalSince1970
        reload(force: true)
    }

    @objc private func revealState() {
        NSWorkspace.shared.activateFileViewerSelecting([stateURL])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: launch at login

    private var agentPlistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    private func launchAtLoginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    /// Enabling and disabling only writes or removes the LaunchAgent plist.
    /// launchd loads ~/Library/LaunchAgents at login by itself, so there is no
    /// reason to bootstrap the job here - doing that would start a SECOND copy
    /// of an already running app, and the matching `bootout` on disable would
    /// terminate the very instance the user is clicking in.
    @objc private func toggleLaunchAtLogin() {
        if launchAtLoginEnabled() {
            try? FileManager.default.removeItem(at: agentPlistURL)
            return
        }
        // Bundle path: .../Claude Status.app/Contents/MacOS/ClaudeStatus
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        do {
            try FileManager.default.createDirectory(
                at: agentPlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentPlistURL)
        } catch {
            NSSound.beep()
        }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
