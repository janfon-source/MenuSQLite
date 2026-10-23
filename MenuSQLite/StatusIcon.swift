import AppKit

/// The menu bar icon: a feather, after SQLite's quill, in the same plain style as 隨手MySQL's
/// dolphin and 隨手記's pen; a template image, so it takes the menu bar's color.
enum StatusIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            feather()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// A leaf-shaped vane leaning to the top right, with a hairline down its middle and a notch in
    /// one edge, and the quill's shaft running out below it.
    private static func feather() {
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
}
