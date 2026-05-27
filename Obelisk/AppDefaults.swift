import Foundation

enum ObeliskAppDefaults {
    static let silentAddEnabledKey = "silentAddEnabled"
    static let openHiddenBookmarksIncognitoKey = "openHiddenBookmarksIncognito"

    static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            silentAddEnabledKey: true,
            openHiddenBookmarksIncognitoKey: true
        ])
        TitleOptimizationPreferences.register(in: defaults)
        BookmarkListSortMode.migratePinnedSortModeIfNeeded(in: defaults)
    }
}
