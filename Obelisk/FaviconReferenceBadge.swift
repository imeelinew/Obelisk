import AppKit

/// Bottom-trailing badge for bookmarks in the "recently added" group.
enum FaviconReferenceBadge {
    static let systemImageName = "arrow.uturn.backward.circle.fill"

    static func badgeDiameter(forFaviconEdge edge: CGFloat) -> CGFloat {
        edge * 0.92
    }

    static func badgeCenterOffset(forFaviconEdge edge: CGFloat) -> NSSize {
        let diameter = badgeDiameter(forFaviconEdge: edge)
        return NSSize(width: -diameter * 0.12, height: diameter * 0.18)
    }

    /// Canvas with transparent padding so the badge can extend past the favicon.
    static func layoutCanvasSize(forFaviconEdge edge: CGFloat) -> NSSize {
        let overflow = badgeDiameter(forFaviconEdge: edge) / 2
        return NSSize(width: edge + overflow, height: edge + overflow)
    }

    static func badgeImage(
        diameter: CGFloat,
        systemImageName: String = Self.systemImageName
    ) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        if let context = NSGraphicsContext.current {
            context.imageInterpolation = .high
        }

        drawBadge(in: NSRect(origin: .zero, size: size), systemImageName: systemImageName)
        image.size = size
        image.isTemplate = false
        return image
    }

    private static func drawBadge(in rect: NSRect, systemImageName: String) {
        NSGraphicsContext.saveGraphicsState()

        let pointSize = rect.width
        let green = NSColor(red: 0.18, green: 0.78, blue: 0.38, alpha: 1)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, green]))
        if let symbol = NSImage(systemSymbolName: systemImageName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        {
            symbol.draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
