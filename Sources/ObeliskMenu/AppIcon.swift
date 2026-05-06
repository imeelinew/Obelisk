import AppKit

enum AppIcon {
    static func image(size: NSSize? = nil) -> NSImage {
        let base = Bundle.module.url(forResource: "AppIcon", withExtension: "png")
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
