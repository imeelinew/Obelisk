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
