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

struct StateFile: Decodable {
    let updatedAt: Double?
    let sessions: [String: SessionRecord]
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
