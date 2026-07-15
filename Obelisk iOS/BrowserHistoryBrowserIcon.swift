import ObeliskCore
import SwiftUI

struct BrowserHistoryBrowserIconView: View {
    let browser: BrowserHistoryBrowser
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let assetName = browser.iconAssetName {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
            } else {
                Image(systemName: browser.fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private extension BrowserHistoryBrowser {
    var iconAssetName: String? {
        switch self {
        case .dia: return "BrowserDia"
        case .chrome: return "BrowserChrome"
        case .edge: return "BrowserEdge"
        case .brave: return "BrowserBrave"
        case .arc: return "BrowserArc"
        case .vivaldi: return "BrowserVivaldi"
        case .opera: return "BrowserOpera"
        case .chromium: return nil
        case .firefox: return "BrowserFirefox"
        case .safari: return "BrowserSafari"
        }
    }
}
