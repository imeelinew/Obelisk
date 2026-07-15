import ObeliskCore
import SwiftUI

struct BrowserHistoryBrowserIconView: View {
    let browser: BrowserHistoryBrowser
    var size: CGFloat = 16

    var body: some View {
        Image(browser.iconAssetName)
            .resizable()
            .renderingMode(.original)
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private extension BrowserHistoryBrowser {
    var iconAssetName: String {
        switch self {
        case .dia: return "BrowserDia"
        case .chrome: return "BrowserChrome"
        case .safari: return "BrowserSafari"
        }
    }
}
