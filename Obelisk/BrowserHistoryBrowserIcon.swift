import AppKit
import SwiftUI

/// Shows the actual browser application icon whenever that browser is installed.
/// Keeping this lookup at display time means Obelisk never needs to ship stale
/// copies of third-party brand assets.
@MainActor
enum BrowserHistoryBrowserIcon {
    private static var cache: [BrowserHistoryBrowser: NSImage] = [:]

    static func image(for browser: BrowserHistoryBrowser) -> NSImage {
        if let cachedImage = cache[browser] {
            return cachedImage
        }

        let image: NSImage
        if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) {
            image = NSWorkspace.shared.icon(forFile: applicationURL.path)
        } else if let resourceName = browser.bundledIconResourceName,
                  let resourceURL = Bundle.main.url(forResource: resourceName, withExtension: "svg"),
                  let bundledImage = NSImage(contentsOf: resourceURL) {
            image = bundledImage
        } else {
            image = NSImage(
                systemSymbolName: browser.fallbackSystemImage,
                accessibilityDescription: browser.title
            ) ?? NSImage()
        }
        image.size = NSSize(width: 18, height: 18)
        cache[browser] = image
        return image
    }
}

struct BrowserHistoryBrowserIconView: View {
    let browser: BrowserHistoryBrowser
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: BrowserHistoryBrowserIcon.image(for: browser))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
