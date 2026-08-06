// Draws the app icon and writes an .iconset directory (build.sh turns it into
// AppIcon.icns with iconutil).
//
//   swiftc -swift-version 5 tools/make-icon/main.swift -o /tmp/make-icon
//   /tmp/make-icon iconset <out.iconset>     # the real thing
//   /tmp/make-icon preview <out.png>         # side-by-side sheet for eyeballing
import AppKit

// State colours, kept in step with app/StatusIcon.swift.
let blue = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1)
let orange = NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)
let green = NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
let red = NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1)

/// macOS icons sit in a rounded square that occupies 824/1024 of the canvas.
func drawPlate(side: CGFloat) {
    let inset = side * 100.0 / 1024.0
    let plate = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = plate.width * 0.2237

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = side * 0.018
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.008)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()

    let path = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
    NSGradient(colors: [
        NSColor(srgbRed: 0.22, green: 0.24, blue: 0.28, alpha: 1),
        NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1),
    ])?.draw(in: path, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // A hairline of light along the top edge reads as a bevel at large sizes
    // and simply vanishes at 16pt.
    NSGraphicsContext.saveGraphicsState()
    path.setClip()
    let rim = NSBezierPath(roundedRect: plate.insetBy(dx: side * 0.004, dy: side * 0.004),
                           xRadius: radius, yRadius: radius)
    rim.lineWidth = side * 0.008
    NSColor.white.withAlphaComponent(0.10).setStroke()
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

/// Variant A: the running spinner, exactly the menu bar's "working" glyph.
func drawSpinner(side: CGFloat) {
    let c = NSPoint(x: side / 2, y: side / 2)
    let r = side * 0.245
    let w = side * 0.082

    let track = NSBezierPath()
    track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
    track.lineWidth = w
    NSColor.white.withAlphaComponent(0.16).setStroke()
    track.stroke()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: r, startAngle: 55, endAngle: 55 + 250)
    arc.lineWidth = w
    arc.lineCapStyle = .round
    blue.setStroke()
    arc.stroke()
}

/// Variant B: one arc per state - says "status indicator" rather than "busy".
func drawSegments(side: CGFloat) {
    let c = NSPoint(x: side / 2, y: side / 2)
    // Below ~32pt the segments start to smear together, so widen the stroke and
    // the gaps rather than letting the ring turn into a coloured smudge.
    let small = side <= 32
    let r = side * (small ? 0.250 : 0.245)
    let w = side * (small ? 0.098 : 0.082)

    let track = NSBezierPath()
    track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
    track.lineWidth = w
    NSColor.white.withAlphaComponent(0.10).setStroke()
    track.stroke()

    // green next to orange next to red keeps the two warm hues apart
    let order: [NSColor] = [blue, orange, green, red]
    let sweep: CGFloat = small ? 68 : 76
    let gap: CGFloat = small ? 22 : 14
    for (i, colour) in order.enumerated() {
        let start = 90 + CGFloat(i) * (sweep + gap)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: r, startAngle: start, endAngle: start + sweep)
        arc.lineWidth = w
        arc.lineCapStyle = .round
        colour.setStroke()
        arc.stroke()
    }
}

func render(side: CGFloat, variant: String) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
        drawPlate(side: side)
        if variant == "segments" { drawSegments(side: side) } else { drawSpinner(side: side) }
        return true
    }
    return image
}

func png(_ image: NSImage, side: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "preview"
let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/icon-preview.png"
let variant = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "segments"

if mode == "iconset" {
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    // The set macOS actually asks for.
    let sizes: [(Int, String)] = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]
    for (px, name) in sizes {
        // Drawn at the target size, not downscaled from 1024: strokes stay crisp.
        let data = png(render(side: CGFloat(px), variant: variant), side: px)
        try! data.write(to: URL(fileURLWithPath: out + "/" + name))
    }
    print(out)
} else {
    // Comparison sheet: both variants at the sizes people actually see.
    let shown = [128, 64, 32, 16]
    let pad: CGFloat = 22
    let width = CGFloat(shown.reduce(0, +)) + pad * CGFloat(shown.count + 1)
    let rowH: CGFloat = 128 + pad * 2
    let sheet = NSImage(size: NSSize(width: width, height: rowH * 2))
    sheet.lockFocus()
    NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: rowH * 2).fill()
    for (row, name) in ["segments", "spinner"].enumerated() {
        var x = pad
        for side in shown {
            let y = rowH * CGFloat(1 - row) + pad
            render(side: CGFloat(side), variant: name)
                .draw(in: NSRect(x: x, y: y, width: CGFloat(side), height: CGFloat(side)))
            x += CGFloat(side) + pad
        }
    }
    sheet.unlockFocus()
    try! sheet.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
        .representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: out))
    print(out)
}
