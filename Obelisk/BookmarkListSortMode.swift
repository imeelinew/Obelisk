import Foundation

enum BookmarkListSortMode: String, CaseIterable, Identifiable {
    case name
    case recentlyAdded
    case frequency

    static let bookmarksStorageKey = "bookmarkListSortMode"
    static let pinnedStorageKey = "pinnedBookmarkListSortMode"
    static let collectionsStorageKey = "bookmarkCollectionListSortMode"
    static let hiddenStorageKey = "hiddenBookmarkListSortMode"
    static let storageKey = bookmarksStorageKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "按名称"
        case .recentlyAdded: return "按最近添加"
        case .frequency: return "按使用频率"
        }
    }

    static var stored: BookmarkListSortMode { storedForUngrouped }
    static var storedForBookmarks: BookmarkListSortMode { storedForUngrouped }
    static var storedForUngrouped: BookmarkListSortMode { stored(for: bookmarksStorageKey) }
    static var storedForPinned: BookmarkListSortMode {
        migratePinnedSortModeIfNeeded()
        return stored(for: pinnedStorageKey)
    }
    static var storedForCollections: BookmarkListSortMode { stored(for: collectionsStorageKey) }
    static var storedForHiddenBookmarks: BookmarkListSortMode { stored(for: hiddenStorageKey) }

    static func migratePinnedSortModeIfNeeded(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: pinnedStorageKey) == nil else { return }
        if let raw = defaults.string(forKey: bookmarksStorageKey),
           BookmarkListSortMode(rawValue: raw) != nil {
            defaults.set(raw, forKey: pinnedStorageKey)
        }
    }

    func sorted(
        _ bookmarks: [Bookmark],
        usage: [UUID: UsageRecord] = [:],
        now: Date = Date()
    ) -> [Bookmark] {
        switch self {
        case .name:
            return bookmarks.sorted { lhs, rhs in
                Self.isOrderedByName(lhs, before: rhs)
            }
        case .recentlyAdded:
            return bookmarks.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return Self.isOrderedByName(lhs, before: rhs)
            }
        case .frequency:
            return UsageStore.frecencySorted(among: bookmarks, usage: usage, now: now)
        }
    }

    private static func isOrderedByName(_ lhs: Bookmark, before rhs: Bookmark) -> Bool {
        let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }

        let urlComparison = lhs.url.localizedStandardCompare(rhs.url)
        if urlComparison != .orderedSame {
            return urlComparison == .orderedAscending
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func stored(for key: String) -> BookmarkListSortMode {
        BookmarkListSortMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .name
    }
}


enum BookmarkSearchMatcher {
    static func matches(bookmark: Bookmark, query: String) -> Bool {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return true }

        let collapsedQuery = collapsed(normalizedQuery)
        return searchableStrings(for: bookmark).contains { value in
            let normalizedValue = normalized(value)
            guard !normalizedValue.isEmpty else { return false }
            if normalizedValue.contains(normalizedQuery) {
                return true
            }

            let pinyinValue = pinyin(normalizedValue)
            return pinyinValue.contains(normalizedQuery)
                || collapsed(pinyinValue).contains(collapsedQuery)
                || initials(from: pinyinValue).contains(collapsedQuery)
        }
    }

    private static func searchableStrings(for bookmark: Bookmark) -> [String] {
        var values = [bookmark.title, bookmark.url]
        if let originalTitle = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !originalTitle.isEmpty,
           originalTitle != bookmark.title {
            values.append(originalTitle)
        }
        return values
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    private static func pinyin(_ value: String) -> String {
        let latin = (value as NSString).applyingTransform(.toLatin, reverse: false) ?? value
        return normalized((latin as NSString).applyingTransform(.stripDiacritics, reverse: false) ?? latin)
    }

    private static func collapsed(_ value: String) -> String {
        value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func initials(from value: String) -> String {
        value
            .split { !$0.isLetter && !$0.isNumber }
            .compactMap(\.first)
            .map(String.init)
            .joined()
    }
}

