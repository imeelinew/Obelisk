import AppKit

enum AppIcon {
    static func menuBarImage() -> NSImage {
        let symbol = (Bundle.main.resourceURL?.appendingPathComponent("PyramidSymbol.svg"))
            .flatMap(NSImage.init(contentsOf:))
            ?? Bundle.module.url(forResource: "PyramidSymbol", withExtension: "svg")
            .flatMap(NSImage.init(contentsOf:))
            ?? image(size: NSSize(width: 18, height: 18))

        let copy = symbol.copy() as? NSImage ?? symbol
        copy.size = NSSize(width: 18, height: 18)
        copy.isTemplate = true
        return copy
    }

    static func image(size: NSSize? = nil) -> NSImage {
        let base = (Bundle.main.resourceURL?.appendingPathComponent("AppIcon.png"))
            .flatMap(NSImage.init(contentsOf:))
            ?? Bundle.module.url(forResource: "AppIcon", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "Obelisk")
            ?? NSImage(size: NSSize(width: 18, height: 18))

        guard let size else { return base }

        let copy = base.copy() as? NSImage ?? base
        copy.size = size
        copy.isTemplate = false
        return copy
    }
}
