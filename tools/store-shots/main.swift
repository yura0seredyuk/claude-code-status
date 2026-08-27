// Generates App Store screenshots at a size App Store Connect will accept.
//
//   swiftc -swift-version 5 app/StatusIcon.swift tools/store-shots/main.swift -o /tmp/shots
//   /tmp/shots store/screenshots
//
// Connect wants 16:10, at least 1280x800 and at most 2880x1800, flattened RGB
// with no alpha channel. A crop of the menu is none of those things, which is
// why the menu is captured with the real drawing code and then composited onto
// a canvas at the size Apple asks for.
//
// The menu is drawn at its native pixel size rather than scaled up: 355 points
// on a Retina display is 710 pixels, and that is exactly how large it appears
// in a real 2880x1800 screenshot. Enlarging it would be a nicer picture and a
// false one.

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let canvas = NSSize(width: 2880, height: 1800)
let scale: CGFloat = 2          // points to pixels on the canvas
let now = Date().timeIntervalSince1970

// ---------------------------------------------------------------------------
// the menu, built from the shipping code
// ---------------------------------------------------------------------------

func window(_ percent: Double, _ resets: Double, captured: Double = 0) -> LimitWindow {
    let json = """
    {"used_percentage":\(percent),"resets_at":\(now + resets),"captured_at":\(now - captured)}
    """
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(LimitWindow.self, from: json.data(using: .utf8)!)
}

func sessionItem(_ name: String, _ status: Status, _ subtitle: String) -> NSMenuItem {
    let item = NSMenuItem(title: name, action: #selector(NSApplication.terminate(_:)),
                          keyEquivalent: "")
    let title = NSMutableAttributedString(
        string: "\(name) — \(status.label)",
        attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
    title.append(NSAttributedString(string: "\n" + subtitle, attributes: [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.secondaryLabelColor]))
    item.attributedTitle = title
    item.image = statusImage(status: status, badge: false, phase: 0.2)
    return item
}

func limitItem(_ row: LimitRow, _ widest: CGFloat, _ font: NSFont) -> NSMenuItem {
    let style = NSMutableParagraphStyle()
    style.tabStops = [
        NSTextTab(textAlignment: .right, location: ceil(widest) + 46, options: [:]),
        NSTextTab(textAlignment: .left, location: ceil(widest) + 56, options: [:]),
    ]
    let title = NSMutableAttributedString(
        string: row.label + "\t" + row.percentText,
        attributes: [.font: font, .paragraphStyle: style,
                     .foregroundColor: NSColor.labelColor])
    let detail = row.detail(now: now)
    if !detail.isEmpty {
        title.append(NSAttributedString(string: "\t" + detail, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .paragraphStyle: style, .foregroundColor: NSColor.secondaryLabelColor]))
    }
    let item = NSMenuItem(title: row.label, action: nil, keyEquivalent: "")
    item.attributedTitle = title
    item.image = limitBarImage(percent: row.percent)
    return item
}

func buildMenu(_ shot: Shot) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false

    let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    header.attributedTitle = NSAttributedString(
        string: "Claude Code — \(shot.aggregate.label)",
        attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())

    for (name, status, subtitle) in shot.sessions {
        menu.addItem(sessionItem(name, status, subtitle))
    }

    if !shot.limits.isEmpty {
        menu.addItem(.separator())
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let widest = shot.limits
            .map { ($0.label as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 130
        for row in shot.limits { menu.addItem(limitItem(row, widest, font)) }
    }

    menu.addItem(.separator())
    let sound = NSMenuItem(title: "Sound alerts", action: #selector(NSApplication.terminate(_:)),
                           keyEquivalent: "")
    sound.state = .on
    menu.addItem(sound)
    let notify = NSMenuItem(title: "Limit alerts", action: #selector(NSApplication.terminate(_:)),
                            keyEquivalent: "")
    notify.state = .on
    menu.addItem(notify)
    menu.addItem(NSMenuItem(title: "Open at login",
                            action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    return menu
}

// ---------------------------------------------------------------------------
// what each screenshot says
// ---------------------------------------------------------------------------

struct Shot {
    let file: String
    let caption: String
    let sub: String
    let aggregate: Status
    let sessions: [(String, Status, String)]
    let limits: [LimitRow]
}

let shots: [Shot] = [
    Shot(file: "01-waiting",
         caption: "Know the moment Claude needs you",
         sub: "One glance at the menu bar instead of cycling through terminals.",
         aggregate: .waiting,
         sessions: [
            ("mebelmarket", .waiting, "Permission needed: Bash · rm -rf node_modules"),
            ("berig", .working, "Bash: npm test · 12s · 4 tool calls"),
         ],
         limits: [limitRow(.session, window(76, 8040)),
                  limitRow(.week, window(28, 172800))]),
    Shot(file: "02-limits",
         caption: "See your plan limits before you hit them",
         sub: "The 5-hour and weekly windows, with the time each one resets.",
         aggregate: .working,
         sessions: [("statuslamp", .working, "Edit: main.swift · 1m 4s · 22 tool calls")],
         limits: [limitRow(.session, window(91, 2400)),
                  limitRow(.week, window(64, 340000))]),
    Shot(file: "03-errors",
         caption: "A failed turn is not a silent one",
         sub: "Rate limits, API failures and tool errors all reach the icon.",
         aggregate: .error,
         sessions: [
            ("myntkaup-app", .error, "Rate limit · resets in 41m"),
            ("stubbs", .done, "“All tests pass” · 3m ago"),
         ],
         limits: [limitRow(.session, window(100, 2460)),
                  limitRow(.week, window(71, 300000))]),
]

// ---------------------------------------------------------------------------
// capture and compose
//
// One screenshot per process. NSMenu.popUp is modal and drives its own run
// loop; re-entering it for a second capture in the same process does not come
// back, so the no-argument form re-execs itself once per shot.
// ---------------------------------------------------------------------------

/// App Store Connect rejects a screenshot with an alpha channel, and a captured
/// menu always has one. Flattening cannot be done by drawing straight into an
/// alpha-less bitmap, though: CoreGraphics has no 24-bit RGB context, so asking
/// NSGraphicsContext for one returns nil and the first draw call traps. Compose
/// with alpha over an opaque ground, then drop the channel.
func flatten(_ rep: NSBitmapImageRep) -> NSBitmapImageRep? {
    guard let source = rep.cgImage,
          let context = CGContext(
              data: nil, width: source.width, height: source.height,
              bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
    guard let flat = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: flat)
}

func compose(_ shot: Shot, menu menuRep: NSBitmapImageRep?) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let full = NSRect(origin: .zero, size: canvas)
    // The app lives on a menu bar at the top of a screen; the ground says so
    // without pretending to be a photograph of somebody's desktop.
    let ground = NSGradient(colors: [
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1),
        NSColor(srgbRed: 0.05, green: 0.06, blue: 0.07, alpha: 1)])
    ground?.draw(in: full, angle: -90)

    let barHeight: CGFloat = 24 * scale
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06).setFill()
    NSRect(x: 0, y: canvas.height - barHeight, width: canvas.width, height: barHeight).fill()

    let iconSide: CGFloat = 18 * scale
    let icon = statusImage(status: shot.aggregate, badge: false, phase: 0.2)
    icon.draw(in: NSRect(x: canvas.width / 2 - iconSide / 2,
                         y: canvas.height - barHeight + (barHeight - iconSide) / 2,
                         width: iconSide, height: iconSide))

    let clock = NSAttributedString(string: "Wed 14:22", attributes: [
        .font: NSFont.systemFont(ofSize: 11 * scale, weight: .medium),
        .foregroundColor: NSColor(white: 1, alpha: 0.75)])
    clock.draw(at: NSPoint(x: canvas.width - clock.size().width - 24 * scale,
                           y: canvas.height - barHeight + (barHeight - clock.size().height) / 2))

    let centred = NSMutableParagraphStyle()
    centred.alignment = .center
    let inset: CGFloat = 200
    NSAttributedString(string: shot.caption, attributes: [
        .font: NSFont.systemFont(ofSize: 64, weight: .semibold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: centred,
    ]).draw(in: NSRect(x: inset, y: canvas.height - 340,
                       width: canvas.width - inset * 2, height: 100))
    NSAttributedString(string: shot.sub, attributes: [
        .font: NSFont.systemFont(ofSize: 32, weight: .regular),
        .foregroundColor: NSColor(white: 1, alpha: 0.62),
        .paragraphStyle: centred,
    ]).draw(in: NSRect(x: inset, y: canvas.height - 420,
                       width: canvas.width - inset * 2, height: 60))

    // The representation is drawn directly rather than wrapped in an NSImage:
    // bitmapImageRepForCachingDisplay reports its size in points while holding
    // twice as many pixels, and an NSImage sized in pixels finds no
    // representation that matches it and draws nothing at all.
    //
    // The rect is the pixel size, not the point size: 355 points on a Retina
    // display is 710 pixels, which is exactly how large the menu appears in a
    // real 2880x1800 screenshot. Enlarging it would be a nicer picture and a
    // false one.
    if let menuRep = menuRep {
        let size = NSSize(width: menuRep.pixelsWide, height: menuRep.pixelsHigh)
        let rect = NSRect(x: (canvas.width - size.width) / 2,
                          y: canvas.height - 700 - size.height,
                          width: size.width, height: size.height)
        NSColor(white: 0, alpha: 0.5).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -20, dy: -20),
                     xRadius: 28, yRadius: 28).fill()
        menuRep.draw(in: rect)
    }

    NSGraphicsContext.restoreGraphicsState()
    return flatten(rep)?.representation(using: .png, properties: [:])
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Driver: no index means "make them all", one child process each.
guard CommandLine.arguments.count > 2, let index = Int(CommandLine.arguments[2]),
      shots.indices.contains(index) else {
    var failed = false
    for i in shots.indices {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        task.arguments = [outDir, String(i)]
        try? task.run()
        task.waitUntilExit()
        // Reported, not swallowed: a driver that hides a crashing child is a
        // driver that makes you debug it blind.
        if task.terminationStatus != 0 {
            print("  FAILED \(shots[i].file) (exit \(task.terminationStatus))")
            failed = true
        }
    }
    exit(failed ? 1 : 0)
}

let shot = shots[index]
let menu = buildMenu(shot)
var wrote = false

let timer = Timer(timeInterval: 0.7, repeats: false) { _ in
    var captured: NSBitmapImageRep?
    for w in NSApp.windows where String(describing: type(of: w)).contains("Menu") {
        guard let view = w.contentView, view.bounds.width > 10,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
        view.cacheDisplay(in: view.bounds, to: rep)
        captured = rep
    }
    if let data = compose(shot, menu: captured) {
        try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(shot.file).png"))
        print("  \(shot.file).png  \(Int(canvas.width))x\(Int(canvas.height))  \(data.count / 1024) KB")
        wrote = true
    }
    menu.cancelTracking()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exit(wrote ? 0 : 3) }
}
RunLoop.main.add(timer, forMode: .common)
menu.popUp(positioning: nil, at: NSPoint(x: 200, y: 700), in: nil)
RunLoop.main.run(until: Date().addingTimeInterval(3))
exit(wrote ? 0 : 3)
