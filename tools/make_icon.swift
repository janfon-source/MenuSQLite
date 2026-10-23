// Renders MenuSQLite/AppIcon.icns.  Run from MenuSQLiteMac/:  swift tools/make_icon.swift
// With a path (swift tools/make_icon.swift preview.png), writes a 512px preview there instead.
import AppKit

// SQLite's own blues: a deep navy to a clear blue behind, a pale sky blue for the feather.
let backTop = NSColor(red: 0.118, green: 0.420, blue: 0.659, alpha: 1)
let backBottom = NSColor(red: 0.039, green: 0.192, blue: 0.318, alpha: 1)
let disk = NSColor(red: 0.937, green: 0.965, blue: 0.984, alpha: 1)
let edge = NSColor(red: 0.584, green: 0.737, blue: 0.851, alpha: 1)
let ink = NSColor(red: 0.039, green: 0.231, blue: 0.380, alpha: 1)
let feather = NSColor(red: 0.592, green: 0.851, blue: 0.965, alpha: 1)

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

    // A database: a cylinder, its top seen from above, with a band round its front. It sits a
    // little left, to leave room for the feather.
    let width = s * 0.44, rise = s * 0.12           // the ellipses' width and height
    let left = s * 0.22
    let bottom = s * 0.24, top = s * 0.66            // centers of the bottom and top ellipses
    let line = s * 0.014
    func oval(_ center: CGFloat) -> NSRect { NSRect(x: left, y: center - rise / 2, width: width, height: rise) }

    let side = NSBezierPath(rect: NSRect(x: left, y: bottom, width: width, height: top - bottom))
    side.append(NSBezierPath(ovalIn: oval(bottom)))
    disk.setFill()
    side.fill()

    // The band and the bottom rim: only the front half of each ellipse shows.
    edge.setStroke()
    for center in [bottom, top - (top - bottom) * 0.28] {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: s, height: center)).addClip()
        let band = NSBezierPath(ovalIn: oval(center))
        band.lineWidth = line
        band.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
    let topFace = NSBezierPath(ovalIn: oval(top))
    NSColor.white.setFill()
    topFace.fill()
    topFace.lineWidth = line
    topFace.stroke()

    // "SQL" across the front, below the band: what kind of database it is, at a glance.
    let text = NSAttributedString(string: "SQL", attributes: [
        .font: NSFont.systemFont(ofSize: s * 0.135, weight: .heavy),
        .foregroundColor: ink,
        .kern: s * 0.004,
    ])
    let size = text.size()
    let textMid = bottom + (top - (top - bottom) * 0.28 - bottom) / 2 - rise * 0.12
    text.draw(at: NSPoint(x: left + (width - size.width) / 2, y: textMid - size.height / 2))

    // A quill feather leaning on the cylinder's right, after SQLite's own: a curved vane either
    // side of a shaft, its tip high on the right.
    NSGraphicsContext.saveGraphicsState()
    square.addClip()
    let base = NSPoint(x: s * 0.58, y: s * 0.15)      // where the shaft ends, bottom left
    let tip = NSPoint(x: s * 0.85, y: s * 0.82)
    let vane = NSBezierPath()
    vane.move(to: NSPoint(x: s * 0.645, y: s * 0.29))
    vane.curve(to: tip, controlPoint1: NSPoint(x: s * 0.60, y: s * 0.50), controlPoint2: NSPoint(x: s * 0.72, y: s * 0.72))
    vane.curve(to: NSPoint(x: s * 0.705, y: s * 0.27), controlPoint1: NSPoint(x: s * 0.90, y: s * 0.64), controlPoint2: NSPoint(x: s * 0.84, y: s * 0.40))
    vane.close()
    // A dark outline parts the feather from the cylinder where they overlap.
    backBottom.withAlphaComponent(0.55).setStroke()
    vane.lineWidth = s * 0.022
    vane.stroke()
    feather.setFill()
    vane.fill()
    // Notches in the vane, as a real feather has, kept inside it.
    NSGraphicsContext.saveGraphicsState()
    vane.addClip()
    for (from, to) in [(NSPoint(x: s * 0.62, y: s * 0.56), NSPoint(x: s * 0.72, y: s * 0.50)),
                       (NSPoint(x: s * 0.90, y: s * 0.48), NSPoint(x: s * 0.80, y: s * 0.44))] {
        let notch = NSBezierPath()
        notch.move(to: from)
        notch.line(to: to)
        notch.lineWidth = s * 0.014
        backTop.setStroke()
        notch.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    let shaft = NSBezierPath()
    shaft.move(to: base)
    shaft.curve(to: tip, controlPoint1: NSPoint(x: s * 0.71, y: s * 0.40), controlPoint2: NSPoint(x: s * 0.80, y: s * 0.64))
    shaft.lineWidth = s * 0.016
    shaft.lineCapStyle = .round
    NSColor.white.setStroke()
    shaft.stroke()
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
