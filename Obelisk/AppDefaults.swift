import Foundation

enum ObeliskAppDefaults {
    static let openHiddenBookmarksIncognitoKey = "openHiddenBookmarksIncognito"

    private static let professionalSidebarDebugDefaultsVersionKey = "professionalSidebarDebugDefaultsVersion"
    private static let professionalSidebarDebugDefaultsVersion = 2
    private static let professionalSidebarIconSizeKey = "debugProfessionalSidebarIconSize"
    private static let professionalSidebarLabelSpacingKey = "debugProfessionalSidebarLabelSpacing"
    private static let professionalSidebarLeadingInsetKey = "debugProfessionalSidebarLeadingInset"
    private static let defaultProfessionalSidebarIconSize: Double = 15
    private static let defaultProfessionalSidebarLabelSpacing: Double = 12
    private static let defaultProfessionalSidebarLeadingInset: Double = 6

    static func register(
        in defaults: UserDefaults = .standard,
        preservesUnauthenticatedDisabledEncryption: Bool = false
    ) {
        let hadStoredEncryptionPreference = defaults.object(forKey: LocalJSONEncryption.enabledKey) != nil
        defaults.register(defaults: [
            SidebarIconTheme.storageKey: SidebarIconTheme.colorful.rawValue,
            professionalSidebarIconSizeKey: defaultProfessionalSidebarIconSize,
            professionalSidebarLabelSpacingKey: defaultProfessionalSidebarLabelSpacing,
            professionalSidebarLeadingInsetKey: defaultProfessionalSidebarLeadingInset,
            openHiddenBookmarksIncognitoKey: true,
            LocalJSONEncryption.enabledKey: true,
            LocalJSONEncryption.disabledByAuthenticatedUserKey: false
        ])
        migrateProfessionalSidebarDebugDefaultsIfNeeded(in: defaults)
        LocalJSONEncryption.normalizeDefault(
            in: defaults,
            hadStoredEnabledPreference: hadStoredEncryptionPreference,
            preservesUnauthenticatedDisabledState: preservesUnauthenticatedDisabledEncryption
        )
        TitleOptimizationPreferences.register(in: defaults)
        BookmarkListSortMode.migratePinnedSortModeIfNeeded(in: defaults)
    }

    private static func migrateProfessionalSidebarDebugDefaultsIfNeeded(in defaults: UserDefaults) {
        var version = defaults.integer(forKey: professionalSidebarDebugDefaultsVersionKey)

        if version < 1 {
            if defaults.object(forKey: professionalSidebarIconSizeKey) == nil
                || defaults.double(forKey: professionalSidebarIconSizeKey) == 13 {
                defaults.set(defaultProfessionalSidebarIconSize, forKey: professionalSidebarIconSizeKey)
            }
            if defaults.object(forKey: professionalSidebarLabelSpacingKey) == nil {
                defaults.set(defaultProfessionalSidebarLabelSpacing, forKey: professionalSidebarLabelSpacingKey)
            }
            if defaults.object(forKey: professionalSidebarLeadingInsetKey) == nil
                || defaults.double(forKey: professionalSidebarLeadingInsetKey) == 0 {
                defaults.set(defaultProfessionalSidebarLeadingInset, forKey: professionalSidebarLeadingInsetKey)
            }
            version = 1
            defaults.set(version, forKey: professionalSidebarDebugDefaultsVersionKey)
        }

        if version < 2 {
            // v1 误把间距 12 迁成 2；恢复为 12，与当前默认一致。
            if defaults.double(forKey: professionalSidebarLabelSpacingKey) == 2 {
                defaults.set(defaultProfessionalSidebarLabelSpacing, forKey: professionalSidebarLabelSpacingKey)
            }
            defaults.set(professionalSidebarDebugDefaultsVersion, forKey: professionalSidebarDebugDefaultsVersionKey)
        }
    }
}
