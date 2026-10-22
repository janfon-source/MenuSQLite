// Renders MenuSQLite/AppIcon.icns.  Run from MenuSQLiteMac/:  swift tools/make_icon.swift
import AppKit

let backTop = NSColor(red: 0.180, green: 0.659, blue: 0.592, alpha: 1)
let backBottom = NSColor(red: 0.098, green: 0.447, blue: 0.459, alpha: 1)
let disk = NSColor(red: 0.925, green: 0.965, blue: 0.957, alpha: 1)
let edge = NSColor(red: 0.596, green: 0.792, blue: 0.769, alpha: 1)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // macOS icon grid: ~10% transparent margin around a rounded square.
    let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    NSGradient(starting: backTop, ending: backBottom)!
        .draw(in: NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18), angle: -90)

    // A database: a cylinder, its top seen from above, with two bands round its front.
    let width = s * 0.46, rise = s * 0.12           // the ellipses' width and height
    let left = (s - width) / 2
    let bottom = s * 0.22, top = s * 0.70            // centers of the bottom and top ellipses
    let line = s * 0.016
    func oval(_ center: CGFloat) -> NSRect { NSRect(x: left, y: center - rise / 2, width: width, height: rise) }

    let side = NSBezierPath(rect: NSRect(x: left, y: bottom, width: width, height: top - bottom))
    side.append(NSBezierPath(ovalIn: oval(bottom)))
    disk.setFill()
    side.fill()

    // The bands and the bottom rim: only the front half of each ellipse shows.
    edge.setStroke()
    for center in [bottom, bottom + (top - bottom) / 3, bottom + (top - bottom) * 2 / 3] {
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

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
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
