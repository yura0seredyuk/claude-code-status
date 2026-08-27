import AppKit
import Darwin
import ServiceManagement
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
    private let limitsURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/claude-status/limits.json")
    /// Claude Code's own config, read for one key: the per-model weekly windows
    /// it caches there whenever you open /usage.
    private let usageCacheURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude.json")

    private var sessions: [SessionRecord] = []
    private var live: [SessionRecord] = []
    private var aggregate: Status = .idle
    private var badge = false
    private var phase: Double = 0
    private var lastSignature: String = ""
    private var lastRenderKey: String = ""

    /// nil means the feature was never switched on, and the menu says nothing
    /// about it at all. Once limits.json exists it always has something to say.
    private var limits: LimitsFile?
    private var limitsSignature: String = ""
    private var usageCache: UsageCache?
    private var usageCacheSignature: String = ""

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
    private var limitAlertsEnabled: Bool {
        get { defaults.object(forKey: "limitAlerts") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "limitAlerts") }
    }
    /// Off by default: the menu bar is the user's, and a percentage there
    /// widens the icon and shifts everything to the left of it.
    private var showLimitInMenuBar: Bool {
        get { defaults.bool(forKey: "showLimitInMenuBar") }
        set { defaults.set(newValue, forKey: "showLimitInMenuBar") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        // Off so the usage rows can be full-contrast: AppKit dims a disabled
        // item on top of whatever colour an attributed title asks for, and
        // automatic validation would disable any item without a target.
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading

        sounds[.waiting] = NSSound(named: "Funk")
        sounds[.error] = NSSound(named: "Basso")
        sounds[.done] = NSSound(named: "Glass")

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { _, _ in }

        migrateLegacyLoginItem()
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
    private func signature(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)|\(mtime)"
    }

    private func reload(force: Bool) {
        reloadLimits()
        let sig = signature(stateURL)
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

    /// The status line rewrites limits.json at most once a minute, so this is
    /// a stat on nearly every poll and a parse almost never.
    private func reloadLimits() {
        let sig = signature(limitsURL)
        guard sig != limitsSignature else { return }
        limitsSignature = sig
        limits = readLimits()
        checkLimitAlerts()
    }

    private func readLimits() -> LimitsFile? {
        guard let data = try? Data(contentsOf: limitsURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(LimitsFile.self, from: data)
    }

    /// The window closest to biting, which is the one worth a menu bar digit.
    /// Stale readings are dropped rather than shown: the menu rows have room to
    /// admit "as of 3h ago", two characters in the menu bar do not.
    private var peakLimit: (kind: LimitKind, window: LimitWindow)? {
        guard let file = limits else { return nil }
        let now = Date().timeIntervalSince1970
        return LimitKind.allCases
            .compactMap { kind -> (kind: LimitKind, window: LimitWindow)? in
                guard let window = kind.window(file), window.isLive(now),
                      now - (window.capturedAt ?? 0) <= limitStaleAfter else { return nil }
                return (kind, window)
            }
            .max { $0.window.percent < $1.window.percent }
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

    // MARK: limit alerts

    /// Highest first: crossing 95 announces 95, not 80 and then 95.
    private let limitThresholds = [95, 80]
    /// "You are at 95% of something that refills in 12 minutes" is noise.
    private let limitAlertQuietBefore: Double = 30 * 60
    /// A reading older than this is not news, it is history - so an app that
    /// starts up mid-window arms its thresholds silently instead of chiming.
    private let limitAlertFreshness: Double = 5 * 60

    private func checkLimitAlerts() {
        guard limitAlertsEnabled, let file = limits else { return }
        let now = Date().timeIntervalSince1970
        for kind in LimitKind.allCases {
            guard let window = kind.window(file), window.isLive(now),
                  let used = window.usedPercentage, let resets = window.resetsAt,
                  resets - now > limitAlertQuietBefore else { continue }
            for threshold in limitThresholds where used >= Double(threshold) {
                // Armed per window *generation*: resets_at is the only field
                // that identifies one, and it survives the window vanishing
                // from a payload and coming back, which happens on every fresh
                // terminal before its first API response.
                let key = "limitAlert.\(kind.key).\(threshold)"
                guard defaults.double(forKey: key) != resets else { break }
                defaults.set(resets, forKey: key)
                if now - (window.capturedAt ?? 0) < limitAlertFreshness {
                    alertLimit(kind, threshold: threshold, used: used, resets: resets - now)
                }
                break
            }
        }
    }

    private func alertLimit(_ kind: LimitKind, threshold: Int, used: Double, resets: Double) {
        if soundEnabled { sounds[threshold >= 95 ? .error : .waiting]?.play() }
        guard notificationsEnabled, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(kind.label) — \(Int(used.rounded()))% used"
        content.body = "Resets in \(resetsInText(resets))."
        UNUserNotificationCenter.current().add(
            // A stable identifier, unlike the per-turn alerts: re-posting should
            // replace the banner rather than stack another one behind it.
            UNNotificationRequest(identifier: "limit.\(kind.key).\(threshold)",
                                  content: content, trigger: nil))
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
        let peak = showLimitInMenuBar ? peakLimit : nil
        let percent = peak.map { Int($0.window.percent.rounded()) }
        // Redrawing the icon costs real CPU, and reload() runs twice a second
        // forever. Only redraw when something visible actually changed - while
        // spinning, that means once per animation step.
        let step = aggregate == .working ? Int(phase * 20) : 0
        let key = "\(aggregate.rawValue)|\(badge)|\(active)|\(step)"
            + "|\(peak?.kind.key ?? "-")|\(percent ?? -1)"
        guard key != lastRenderKey else { return }
        lastRenderKey = key

        button.image = statusImage(status: aggregate, badge: badge, phase: phase)

        // One string, two possible tenants. The session count comes first
        // because it says how much is running; the percentage is a warning.
        var pieces: [String] = []
        if active > 1 { pieces.append("\(active)") }
        if let percent = percent { pieces.append("\(percent)%") }
        button.attributedTitle = NSAttributedString(
            string: pieces.isEmpty ? "" : " " + pieces.joined(separator: " · "),
            attributes: [
                // Monospaced digits: otherwise 11% and 48% differ by 4.6pt and
                // every menu bar item to the left of ours twitches on each poll.
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])

        var tip = "Claude Code — \(aggregate.label)"
        if let peak = peak {
            tip += "\n\(peak.kind.label): \(Int(peak.window.percent.rounded()))% used"
        }
        button.toolTip = tip
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        reload(force: true)
        menu.removeAllItems()

        let header = NSMenuItem(title: "Claude Code — \(aggregate.label)", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(
            string: "Claude Code — \(aggregate.label)",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        header.isEnabled = false
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

        addLimitItems(to: menu)

        menu.addItem(.separator())
        menu.addItem(toggle("Sound alerts", on: soundEnabled, action: #selector(toggleSound)))
        menu.addItem(toggle("Notifications", on: notificationsEnabled, action: #selector(toggleNotifications)))
        if limits != nil {
            menu.addItem(toggle("Limit alerts", on: limitAlertsEnabled, action: #selector(toggleLimitAlerts)))
            menu.addItem(toggle("Show usage in menu bar", on: showLimitInMenuBar,
                                action: #selector(toggleLimitInMenuBar)))
        }
        menu.addItem(toggle("Show background sessions", on: showBackground, action: #selector(toggleBackground)))
        // Only the user can clear a "requires approval" state, so say so rather
        // than offering a switch that silently refuses to move.
        menu.addItem(toggle(loginItemStatus == .requiresApproval
                                ? "Open at login — approve in System Settings"
                                : "Open at login",
                            on: launchAtLoginEnabled(), action: #selector(toggleLaunchAtLogin)))
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

    /// Shown only once limits.json exists: an install that never asked for plan
    /// limits should not be nagged about a feature it did not switch on.
    private func addLimitItems(to menu: NSMenu) {
        guard let file = limits else { return }
        let now = Date().timeIntervalSince1970
        var rows = LimitKind.allCases.compactMap { kind -> LimitRow? in
            guard let window = kind.window(file), window.isLive(now) else { return nil }
            return limitRow(kind, window)
        }
        rows += readModelRows(now: now)

        menu.addItem(.separator())
        if rows.isEmpty {
            let why = limitPlaceholder(file, now: now,
                                       sessionsLive: live.contains { !$0.isBackground })
            menu.addItem(infoItem("Plan limits — " + why.text, tip: why.detail))
            return
        }
        // One tab stop for the whole block, measured over the rows actually
        // being drawn: a model name is wider than "Weekly limit (7d)".
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let widest = rows
            .map { ($0.label as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 130
        for row in rows {
            menu.addItem(limitItem(row, now: now, labelWidth: widest, font: font))
        }
    }

    /// ~/.claude.json is 100 kB and Claude Code rewrites it constantly, so it is
    /// parsed on menu open rather than on the twice-a-second poll, and only when
    /// the file actually moved.
    private func readModelRows(now: Double) -> [LimitRow] {
        let sig = signature(usageCacheURL)
        if sig != usageCacheSignature {
            usageCacheSignature = sig
            usageCache = readUsageCache()
        }
        guard let cache = usageCache else { return [] }
        return modelLimitRows(cache, now: now)
    }

    private func readUsageCache() -> UsageCache? {
        guard let data = try? Data(contentsOf: usageCacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(ClaudeConfigFile.self, from: data))?.cachedUsageUtilization
    }

    private func infoItem(_ text: String, tip: String? = nil) -> NSMenuItem {
        let menuItem = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        menuItem.toolTip = tip
        return menuItem
    }

    /// The bar rides in the item's image slot rather than inside the title. The
    /// image column is per item, so a wide bar here leaves the session rows
    /// above it alone - the checkmark column, which is shared, would not.
    private func limitItem(_ row: LimitRow, now: Double,
                           labelWidth: CGFloat, font: NSFont) -> NSMenuItem {
        let style = NSMutableParagraphStyle()
        style.tabStops = [
            NSTextTab(textAlignment: .right, location: ceil(labelWidth) + 46, options: [:]),
            NSTextTab(textAlignment: .left, location: ceil(labelWidth) + 56, options: [:]),
        ]

        let title = NSMutableAttributedString(
            string: row.label + "\t" + row.percentText,
            attributes: [.font: font, .paragraphStyle: style,
                         .foregroundColor: NSColor.labelColor])
        let detail = row.detail(now: now)
        if !detail.isEmpty {
            title.append(NSAttributedString(
                string: "\t" + detail,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                    .paragraphStyle: style,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
        }

        let menuItem = NSMenuItem(title: row.label, action: nil, keyEquivalent: "")
        menuItem.attributedTitle = title
        menuItem.image = limitBarImage(percent: row.percent)
        menuItem.toolTip = "\(row.label): \(row.percentText) used"
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
    @objc private func toggleLimitAlerts() { limitAlertsEnabled.toggle() }
    @objc private func toggleLimitInMenuBar() {
        showLimitInMenuBar.toggle()
        lastRenderKey = ""
        renderIcon()
    }

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
    //
    // SMAppService rather than a hand-written LaunchAgent plist: it is the
    // supported route on macOS 13+, it survives the app moving, and it can say
    // "the user switched this off in System Settings" - a state a plist on disk
    // cannot represent, which is why the old code could show a tick for a login
    // item that was never going to fire.

    private var loginItemStatus: SMAppService.Status { SMAppService.mainApp.status }

    private func launchAtLoginEnabled() -> Bool { loginItemStatus == .enabled }

    /// Where earlier versions wrote the login item by hand. Kept only to migrate
    /// off it: with both the plist and a registration in place, macOS launches
    /// two copies of the app at login.
    private var legacyAgentPlistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    /// Registering first and deleting second keeps the user's setting. If the
    /// registration fails the plist stays: silently losing "open at login" is
    /// worse than the duplicate launch it was meant to prevent.
    private func migrateLegacyLoginItem() {
        guard FileManager.default.fileExists(atPath: legacyAgentPlistURL.path) else { return }
        if loginItemStatus != .enabled {
            do { try SMAppService.mainApp.register() } catch { return }
        }
        try? FileManager.default.removeItem(at: legacyAgentPlistURL)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLoginEnabled() {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Nearly always because the user turned the item off in System
            // Settings, and only they can turn it back on. Take them there
            // instead of beeping at them.
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

// uninstall.sh runs this before deleting the bundle. An SMAppService
// registration outlives the app it points at, and would otherwise sit in System
// Settings as an orphan the user has to clear by hand.
if CommandLine.arguments.contains("--unregister-login-item") {
    try? SMAppService.mainApp.unregister()
    try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist"))
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
