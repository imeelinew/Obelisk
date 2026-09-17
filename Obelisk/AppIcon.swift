import AppKit

enum AppIcon {
    static let menuItemFaviconSize = NSSize(width: 16, height: 16)
    static let menuItemFaviconCanvasSize = NSSize(width: 20, height: 20)

    static func menuBarImage() -> NSImage {
        let rawStyle = UserDefaults.standard.string(forKey: MenuBarIconStyle.storageKey)
        let style = rawStyle.flatMap(MenuBarIconStyle.init(rawValue:)) ?? .outline
        return menuBarImage(style: style)
    }

    static func menuBarImage(style: MenuBarIconStyle) -> NSImage {
        let iconSize = NSSize(width: 17, height: 17)
        let canvasExtraHeight: CGFloat = 2
        let verticalNudge: CGFloat = 1
        let symbolName: String

        switch style {
        case .outline:
            symbolName = "pyramid"
        case .filled:
            symbolName = "pyramid.fill"
        }

        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
            ?? resourceImage(name: "PyramidSymbol", extension: "svg")
        guard let symbol else { return NSImage(size: iconSize) }
        let icon = symbol.copy() as? NSImage ?? symbol
        icon.size = iconSize
        icon.isTemplate = true

        let canvasSize = NSSize(width: iconSize.width, height: iconSize.height + canvasExtraHeight)
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

    static func setMenuItemFavicon(_ image: NSImage, on menuItem: NSMenuItem) {
        let canvas = NSImage(size: menuItemFaviconCanvasSize)
        canvas.lockFocus()
        if let context = NSGraphicsContext.current {
            context.imageInterpolation = .high
        }
        let origin = NSPoint(
            x: (menuItemFaviconCanvasSize.width - menuItemFaviconSize.width) / 2,
            y: (menuItemFaviconCanvasSize.height - menuItemFaviconSize.height) / 2
        )
        image.draw(in: NSRect(origin: origin, size: menuItemFaviconSize))
        canvas.unlockFocus()
        canvas.isTemplate = false
        menuItem.image = canvas
        if #available(macOS 27.0, *) {
            menuItem.preferredImageVisibility = .visible
        }
    }

    private static func resourceImage(name: String, extension pathExtension: String) -> NSImage? {
        (Bundle.main.resourceURL?.appendingPathComponent("\(name).\(pathExtension)"))
            .flatMap(NSImage.init(contentsOf:))
    }
}
