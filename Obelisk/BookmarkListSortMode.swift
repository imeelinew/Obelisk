import Foundation

enum BookmarkListSortMode: String, CaseIterable, Identifiable {
    case name
    case recentlyAdded
    case frequency

    static let bookmarksStorageKey = "bookmarkListSortMode"
    static let pinnedStorageKey = "pinnedBookmarkListSortMode"
    static let collectionsStorageKey = "bookmarkCollectionListSortMode"
    static let hiddenStorageKey = "hiddenBookmarkListSortMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "按名称"
        case .recentlyAdded: return "按最近添加"
        case .frequency: return "按使用频率"
        }
    }

    static var storedForUngrouped: BookmarkListSortMode { stored(for: bookmarksStorageKey) }
    static var storedForPinned: BookmarkListSortMode { stored(for: pinnedStorageKey) }
    static var storedForCollections: BookmarkListSortMode { stored(for: collectionsStorageKey) }
    static var storedForHiddenBookmarks: BookmarkListSortMode { stored(for: hiddenStorageKey) }

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
