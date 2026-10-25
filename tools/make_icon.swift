// Renders MenuSQLite/AppIcon.icns.  Run from MenuSQLiteMac/:  swift tools/make_icon.swift
// With a path (swift tools/make_icon.swift preview.png), writes a 512px preview there instead.
import AppKit

// SQLite's own blues: a deep navy to a clear blue behind.
let backTop = NSColor(red: 0.118, green: 0.420, blue: 0.659, alpha: 1)
let backBottom = NSColor(red: 0.039, green: 0.192, blue: 0.318, alpha: 1)

/// The same feather as the menu bar icon (StatusIcon.swift), in its 18-point box.
func glyph() {
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
    let vane = NSBezierPath()
    vane.move(to: P(4.6, 4.6))
    vane.curve(to: P(17.0, 17.0), controlPoint1: P(4.0, 11.8), controlPoint2: P(9.6, 17.4))
    vane.curve(to: P(4.6, 4.6), controlPoint1: P(17.4, 9.6), controlPoint2: P(11.8, 4.0))
    vane.close()
    vane.fill()

    NSGraphicsContext.current?.compositingOperation = .clear
    let notch = NSBezierPath()
    notch.move(to: P(12.2, 5.6))
    notch.line(to: P(10.6, 9.0))
    notch.line(to: P(13.1, 5.95))
    notch.close()
    notch.fill()
    let rachis = NSBezierPath()
    rachis.move(to: P(6.2, 6.2))
    rachis.line(to: P(13.4, 13.4))
    rachis.lineWidth = 0.7
    rachis.lineCapStyle = .round
    rachis.stroke()
    NSGraphicsContext.current?.compositingOperation = .sourceOver

    let shaft = NSBezierPath()
    shaft.move(to: P(1.4, 1.4))
    shaft.line(to: P(5.4, 5.4))
    shaft.lineWidth = 1.5
    shaft.lineCapStyle = .round
    shaft.stroke()
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // macOS icon grid: ~10% transparent margin around a rounded square.
    let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let square = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: backTop, ending: backBottom)!.draw(in: square, angle: -90)

    // The menu bar icon's shape, white, filling the middle of the square. It's drawn on a layer of
    // its own, so the parts it cuts out show the square through rather than leaving holes.
    let layer = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: layer)
    let place = NSAffineTransform()
    place.translateX(by: s * 0.5, yBy: s * 0.5)
    place.scale(by: s * 0.56 / 18)
    place.translateX(by: -9, yBy: -9)
    place.concat()
    NSColor.white.set()
    glyph()
    NSGraphicsContext.restoreGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = backBottom.withAlphaComponent(0.45)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.02
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    layer.draw(in: NSRect(x: 0, y: 0, width: s, height: s), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if CommandLine.arguments.count > 1 {
    try! render(512).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    exit(0)
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MenuSQLite.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let out = URL(fileURLWithPath: "MenuSQLite/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
