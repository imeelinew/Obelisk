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

    /// Canvas with transparent padding so the badge can extend past the favicon (menu bar).
    static func layoutCanvasSize(forFaviconEdge edge: CGFloat) -> NSSize {
        let overflow = badgeDiameter(forFaviconEdge: edge) / 2
        return NSSize(width: edge + overflow, height: edge + overflow)
    }

    static func faviconRect(inLayoutCanvasForFaviconEdge edge: CGFloat) -> NSRect {
        let overflow = badgeDiameter(forFaviconEdge: edge) / 2
        return NSRect(x: 0, y: overflow, width: edge, height: edge)
    }

    static func badgeRect(faviconRect: NSRect, badgeDiameter: CGFloat) -> NSRect {
        let offset = badgeCenterOffset(forFaviconEdge: faviconRect.width)
        return NSRect(
            x: faviconRect.maxX - badgeDiameter / 2 + offset.width,
            y: faviconRect.minY - badgeDiameter / 2 + offset.height,
            width: badgeDiameter,
            height: badgeDiameter
        )
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

    /// Favicon + corner badge for single-`NSImage` surfaces (menu bar).
    static func composited(
        favicon: NSImage,
        faviconEdge: CGFloat,
        systemImageName: String = Self.systemImageName
    ) -> NSImage {
        let badgeDiameter = badgeDiameter(forFaviconEdge: faviconEdge)
        let outputSize = layoutCanvasSize(forFaviconEdge: faviconEdge)
        let faviconRect = faviconRect(inLayoutCanvasForFaviconEdge: faviconEdge)
        let badgeRect = badgeRect(faviconRect: faviconRect, badgeDiameter: badgeDiameter)

        let output = NSImage(size: outputSize)
        output.lockFocus()
        defer { output.unlockFocus() }

        if let context = NSGraphicsContext.current {
            context.imageInterpolation = .high
        }

        let faviconCopy = favicon.copy() as? NSImage ?? favicon
        faviconCopy.size = faviconRect.size
        faviconCopy.draw(in: faviconRect)

        drawBadge(in: badgeRect, systemImageName: systemImageName)

        output.size = outputSize
        output.isTemplate = false
        return output
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
