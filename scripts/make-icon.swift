// Generates Resources/AppIcon.icns: run `swift scripts/make-icon.swift`
import AppKit

func render(_ size: CGFloat) -> Data {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size / 1024
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bg = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1),
                        NSColor(red: 0.13, green: 0.16, blue: 0.23, alpha: 1)])!.draw(in: bg, angle: 90)
    // right-edge sidebar
    let side = NSBezierPath(roundedRect: NSRect(x: 600 * s, y: 170 * s, width: 254 * s, height: 684 * s), xRadius: 48 * s, yRadius: 48 * s)
    NSColor(white: 1, alpha: 0.10).setFill(); side.fill()
    // bars (revenue up, spend down)
    let green = NSColor(red: 0.20, green: 0.78, blue: 0.50, alpha: 1)
    let red = NSColor(red: 0.95, green: 0.42, blue: 0.37, alpha: 1)
    let heights: [CGFloat] = [180, 260, 220, 340, 420]
    for (i, h) in heights.enumerated() {
        let x = (190 + CGFloat(i) * 78) * s
        green.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 470 * s, width: 50 * s, height: h * s), xRadius: 12 * s, yRadius: 12 * s).fill()
        red.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: (450 - h * 0.35) * s, width: 50 * s, height: h * 0.35 * s), xRadius: 12 * s, yRadius: 12 * s).fill()
    }
    // widget rows in the sidebar
    for i in 0..<4 {
        let y = (720 - CGFloat(i) * 140) * s
        NSColor(white: 1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: 640 * s, y: y, width: 60 * s, height: 60 * s), xRadius: 16 * s, yRadius: 16 * s).fill()
        NSColor(white: 1, alpha: 0.35).setFill()
        NSBezierPath(roundedRect: NSRect(x: 720 * s, y: y + 18 * s, width: 100 * s, height: 24 * s), xRadius: 12 * s, yRadius: 12 * s).fill()
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: dir)
print("Resources/AppIcon.icns")
