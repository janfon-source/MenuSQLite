import AppKit

/// The menu bar icon: a solid rounded square with a quill across it, after SQLite's own mark, as a
/// template image so it takes the menu bar's color.
enum StatusIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            // A solid square, as SQLite's mark has, with a gap cut round the quill lying across it.
            NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 12, height: 12), xRadius: 2.5, yRadius: 2.5).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            let gap = quill(grown: 1.3)
            gap.fill()
            let shaftGap = shaft()
            shaftGap.lineWidth = 3.4
            shaftGap.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            quill(grown: 0).fill()
            let line = shaft()
            line.lineWidth = 1.2
            line.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The quill's shaft, running on below the vane down into the square.
    private static func shaft() -> NSBezierPath {
        let shaft = NSBezierPath()
        shaft.move(to: NSPoint(x: 3.8, y: 3.4))
        shaft.curve(to: NSPoint(x: 8.6, y: 8.4), controlPoint1: NSPoint(x: 5.4, y: 4.8), controlPoint2: NSPoint(x: 7.2, y: 6.8))
        shaft.lineCapStyle = .round
        return shaft
    }

    /// The feather's vane, from low in the square to its tip past the top-right corner;
    /// `grown` widens it, for the gap it cuts in the square.
    private static func quill(grown g: CGFloat) -> NSBezierPath {
        let vane = NSBezierPath()
        vane.move(to: NSPoint(x: 7.6 - g, y: 7.4 - g * 0.3))
        vane.curve(to: NSPoint(x: 16.8 + g * 0.3, y: 16.8 + g * 0.3),
                   controlPoint1: NSPoint(x: 8.6 - g, y: 12.4 + g), controlPoint2: NSPoint(x: 12.6 - g, y: 15.8 + g))
        vane.curve(to: NSPoint(x: 9.2 + g * 0.3, y: 6.4 - g),
                   controlPoint1: NSPoint(x: 16.2 + g, y: 12.6 - g), controlPoint2: NSPoint(x: 13.6 + g, y: 8.0 - g))
        vane.close()
        return vane
    }
}
