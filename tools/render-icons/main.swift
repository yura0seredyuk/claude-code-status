// Dev tool: renders every menu bar icon state to a PNG sheet so the drawing
// code can be eyeballed without launching the app.
//   swiftc app/StatusIcon.swift tools/render-icons/main.swift -o /tmp/render-icons
import AppKit

let states: [(String, Status, Bool)] = [
    ("idle", .idle, false),
    ("working", .working, false),
    ("working+fail", .working, true),
    ("waiting", .waiting, false),
    ("done", .done, false),
    ("error", .error, false),
]

let scale: CGFloat = 5
let cell: CGFloat = 18 * scale
let pad: CGFloat = 14
let labelH: CGFloat = 22
let stripH = cell + pad * 2
let width = CGFloat(states.count) * (cell + pad) + pad
let height = stripH * 2 + labelH

let sheet = NSImage(size: NSSize(width: width, height: height))
sheet.lockFocus()

// two strips: light menu bar on top, dark menu bar below
NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1).setFill()
NSRect(x: 0, y: stripH + labelH, width: width, height: stripH).fill()
NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1).setFill()
NSRect(x: 0, y: labelH, width: width, height: stripH).fill()
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: width, height: labelH).fill()

for (index, entry) in states.enumerated() {
    let (name, status, badge) = entry
    let x = pad + CGFloat(index) * (cell + pad)

    // animated states get sampled mid-rotation
    let icon = statusImage(status: status, badge: badge, phase: 0.15)
    for (row, y) in [(0, stripH + labelH + pad), (1, labelH + pad)] {
        _ = row
        icon.draw(in: NSRect(x: x, y: y, width: cell, height: cell),
                  from: .zero, operation: .sourceOver, fraction: 1,
                  respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.black,
    ]
    let text = name as NSString
    let size = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: x + (cell - size.width) / 2, y: 5), withAttributes: attrs)
}

sheet.unlockFocus()

guard let tiff = sheet.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
    exit(1)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/statuslamp-icons.png"
try! png.write(to: URL(fileURLWithPath: out))
print(out)
