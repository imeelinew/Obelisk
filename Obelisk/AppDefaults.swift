import Foundation

enum ObeliskAppDefaults {
    static let silentAddEnabledKey = "silentAddEnabled"
    static let openHiddenBookmarksIncognitoKey = "openHiddenBookmarksIncognito"

    static func register(
        in defaults: UserDefaults = .standard,
        preservesUnauthenticatedDisabledEncryption: Bool = false
    ) {
        let hadStoredEncryptionPreference = defaults.object(forKey: LocalJSONEncryption.enabledKey) != nil
        defaults.register(defaults: [
            silentAddEnabledKey: true,
            openHiddenBookmarksIncognitoKey: true,
            LocalJSONEncryption.enabledKey: true,
            LocalJSONEncryption.disabledByAuthenticatedUserKey: false
        ])
        LocalJSONEncryption.normalizeDefault(
            in: defaults,
            hadStoredEnabledPreference: hadStoredEncryptionPreference,
            preservesUnauthenticatedDisabledState: preservesUnauthenticatedDisabledEncryption
        )
        TitleOptimizationPreferences.register(in: defaults)
        BookmarkListSortMode.migratePinnedSortModeIfNeeded(in: defaults)
    }
}
