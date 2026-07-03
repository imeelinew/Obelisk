import Foundation

enum ObeliskAppDefaults {
    static let openHiddenBookmarksIncognitoKey = "openHiddenBookmarksIncognito"

    private static let professionalSidebarDebugDefaultsVersionKey = "professionalSidebarDebugDefaultsVersion"
    private static let professionalSidebarDebugDefaultsVersion = 3
    private static let sidebarIconTileSizeKey = "debugSidebarIconTileSize"
    private static let sidebarIconSymbolSizeKey = "debugSidebarIconSymbolSize"
    private static let sidebarIconCornerRadiusKey = "debugSidebarIconCornerRadius"
    private static let professionalSidebarIconSizeKey = "debugProfessionalSidebarIconSize"
    private static let defaultSidebarIconTileSize: Double = 22
    private static let defaultSidebarIconSymbolSize: Double = 11
    private static let defaultSidebarIconCornerRadius: Double = 6
    private static let defaultProfessionalSidebarIconSize: Double = 15

    static func register(
        in defaults: UserDefaults = .standard,
        preservesUnauthenticatedDisabledEncryption: Bool = false
    ) {
        let hadStoredEncryptionPreference = defaults.object(forKey: LocalJSONEncryption.enabledKey) != nil
        defaults.register(defaults: [
            SidebarIconTheme.storageKey: SidebarIconTheme.colorful.rawValue,
            SidebarIconStyle.storageKey: SidebarIconStyle.lucide.rawValue,
            MenuBarIconStyle.storageKey: MenuBarIconStyle.outline.rawValue,
            sidebarIconTileSizeKey: defaultSidebarIconTileSize,
            sidebarIconSymbolSizeKey: defaultSidebarIconSymbolSize,
            sidebarIconCornerRadiusKey: defaultSidebarIconCornerRadius,
            professionalSidebarIconSizeKey: defaultProfessionalSidebarIconSize,
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
        BookmarkAutoGroupingPreferences.register(in: defaults)
        HiddenBookmarkKeywordExclusion.register(in: defaults)
        BookmarkListSortMode.migratePinnedSortModeIfNeeded(in: defaults)
    }

    private static func migrateProfessionalSidebarDebugDefaultsIfNeeded(in defaults: UserDefaults) {
        var version = defaults.integer(forKey: professionalSidebarDebugDefaultsVersionKey)

        if version < 1 {
            if defaults.object(forKey: professionalSidebarIconSizeKey) == nil
                || defaults.double(forKey: professionalSidebarIconSizeKey) == 13 {
                defaults.set(defaultProfessionalSidebarIconSize, forKey: professionalSidebarIconSizeKey)
            }
            version = 1
            defaults.set(version, forKey: professionalSidebarDebugDefaultsVersionKey)
        }

        if version < 3 {
            defaults.set(defaultSidebarIconTileSize, forKey: sidebarIconTileSizeKey)
            defaults.set(defaultSidebarIconSymbolSize, forKey: sidebarIconSymbolSizeKey)
            defaults.set(defaultSidebarIconCornerRadius, forKey: sidebarIconCornerRadiusKey)
            defaults.set(defaultProfessionalSidebarIconSize, forKey: professionalSidebarIconSizeKey)
            defaults.set(professionalSidebarDebugDefaultsVersion, forKey: professionalSidebarDebugDefaultsVersionKey)
        }
    }
}

enum HiddenBookmarkKeywordExclusion {
    static let storageKey = "hiddenBookmarkExcludedURLKeywords"
    static let blockedBookmarkMessage = "无法添加此书签"

    static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            storageKey: ""
        ])
    }

    static func keywords(in defaults: UserDefaults = .standard) -> [String] {
        keywords(from: defaults.string(forKey: storageKey) ?? "")
    }

    static func keywords(from rawValue: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for keyword in rawValue.components(separatedBy: .newlines) {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = trimmed.lowercased()
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(trimmed)
        }
        return result
    }

    static func encoded(_ values: [String]) -> String {
        keywords(from: values.joined(separator: "\n")).joined(separator: "\n")
    }

    static func matches(url: String, defaults: UserDefaults = .standard) -> Bool {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return false }
        return keywords(in: defaults).contains { keyword in
            trimmedURL.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
