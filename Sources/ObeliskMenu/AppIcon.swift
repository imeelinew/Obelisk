import AppKit

enum AppIcon {
    static func menuBarImage() -> NSImage {
        let symbol = resourceImage(name: "PyramidSymbol", extension: "svg")
            ?? image(size: NSSize(width: 18, height: 18))

        let copy = symbol.copy() as? NSImage ?? symbol
        copy.size = NSSize(width: 18, height: 18)
        copy.isTemplate = true
        return copy
    }

    static func image(size: NSSize? = nil) -> NSImage {
        let base = resourceImage(name: "AppIcon", extension: "png")
            ?? NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "Obelisk")
            ?? NSImage(size: NSSize(width: 18, height: 18))

        guard let size else { return base }

        let copy = base.copy() as? NSImage ?? base
        copy.size = size
        copy.isTemplate = false
        return copy
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
}
