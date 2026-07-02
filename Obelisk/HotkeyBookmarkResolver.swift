import Foundation

enum HotkeyBookmarkResolution: Equatable {
    case resolved(url: String, title: String?)
    case failed(message: String, settingsDestination: PermissionSettingsDestination?)
}

enum HotkeyBookmarkResolver {
    static func resolve(currentTab: BrowserCurrentTabResult) -> HotkeyBookmarkResolution {
        switch currentTab {
        case .success(let tab):
            return .resolved(url: tab.url, title: tab.title)
        case .failure(let failure):
            return .failed(
                message: message(for: failure),
                settingsDestination: settingsDestination(for: failure)
            )
        }
    }

    private static func message(for failure: BrowserCurrentTabFailure) -> String {
        switch failure {
        case .noFrontmostApplication, .unsupportedFrontmostApplication:
            return "请先切到要添加的浏览器标签页"
        case .noBrowserWindow:
            return "当前浏览器没有可读取的窗口"
        case .invalidURL:
            return "当前浏览器标签无有效网址"
        case .automationPermissionRequired:
            return "请在“隐私与安全性 > 自动化”允许 Obelisk 控制当前浏览器"
        case .scriptFailed:
            return "无法读取当前浏览器标签"
        case .timedOut:
            return "读取当前浏览器标签超时"
        }
    }

    private static func settingsDestination(for failure: BrowserCurrentTabFailure) -> PermissionSettingsDestination? {
        switch failure {
        case .automationPermissionRequired:
            return .automation
        default:
            return nil
        }
    }
}
