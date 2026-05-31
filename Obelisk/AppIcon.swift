import AppKit

enum AppIcon {
    static func menuBarImage() -> NSImage {
        let iconSize = NSSize(width: 16, height: 16)
        let verticalNudge: CGFloat = 2

        let symbol = resourceImage(name: "PyramidSymbol", extension: "svg")
            ?? image(size: iconSize)
        let icon = symbol.copy() as? NSImage ?? symbol
        icon.size = iconSize
        icon.isTemplate = true

        let canvasSize = NSSize(width: iconSize.width, height: iconSize.height + verticalNudge)
        let canvas = NSImage(size: canvasSize)
        canvas.lockFocus()
        icon.draw(
            at: NSPoint(x: 0, y: verticalNudge),
            from: NSRect(origin: .zero, size: iconSize),
            operation: .sourceOver,
            fraction: 1
        )
        canvas.unlockFocus()
        canvas.size = canvasSize
        canvas.isTemplate = true
        return canvas
    }

    static func image(size: NSSize? = nil) -> NSImage {
        let base = resourceImage(name: "AppIcon", extension: "png")
            ?? generatedAppMark(size: size ?? NSSize(width: 18, height: 18))

        guard let size else { return base }

        let copy = base.copy() as? NSImage ?? base
        copy.size = size
        copy.isTemplate = false
        return copy
    }

    static func faviconPlaceholder(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        NSColor.controlBackgroundColor.withAlphaComponent(0.85).setFill()

        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let radius = max(3, min(size.width, size.height) * 0.22)
        let background = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        background.fill()
        background.stroke()

        NSColor.secondaryLabelColor.withAlphaComponent(0.75).setStroke()
        let lineWidth = max(1, min(size.width, size.height) * 0.08)
        let globeRect = rect.insetBy(dx: size.width * 0.24, dy: size.height * 0.24)
        let globe = NSBezierPath(ovalIn: globeRect)
        globe.lineWidth = lineWidth
        globe.stroke()

        let midX = globeRect.midX
        let vertical = NSBezierPath()
        vertical.move(to: NSPoint(x: midX, y: globeRect.minY))
        vertical.line(to: NSPoint(x: midX, y: globeRect.maxY))
        vertical.lineWidth = lineWidth
        vertical.stroke()

        let horizontal = NSBezierPath()
        horizontal.move(to: NSPoint(x: globeRect.minX, y: globeRect.midY))
        horizontal.line(to: NSPoint(x: globeRect.maxX, y: globeRect.midY))
        horizontal.lineWidth = lineWidth
        horizontal.stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func resourceImage(name: String, extension pathExtension: String) -> NSImage? {
        (Bundle.main.resourceURL?.appendingPathComponent("\(name).\(pathExtension)"))
            .flatMap(NSImage.init(contentsOf:))
            ?? packageResourceURL(name: name, extension: pathExtension)
            .flatMap(NSImage.init(contentsOf:))
    }

    private static func packageResourceURL(name: String, extension pathExtension: String) -> URL? {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource: name, withExtension: pathExtension)
        #else
        nil
        #endif
    }

    private static func generatedAppMark(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: size.width * 0.2, yRadius: size.height * 0.2).fill()

        NSColor.controlAccentColor.setFill()
        let inset = min(size.width, size.height) * 0.24
        let path = NSBezierPath()
        path.move(to: NSPoint(x: size.width / 2, y: size.height - inset))
        path.line(to: NSPoint(x: size.width - inset, y: inset))
        path.line(to: NSPoint(x: inset, y: inset))
        path.close()
        path.fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
