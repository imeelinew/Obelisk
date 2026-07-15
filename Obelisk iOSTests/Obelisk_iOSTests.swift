import Foundation
import ObeliskCore
import ObeliskData
import Testing
@testable import Obelisk_iOS

@MainActor
struct Obelisk_iOSTests {
    @Test func libraryFiltersPrivateAndArchivedBookmarks() {
        let visible = Bookmark(title: "Visible", url: "https://visible.example")
        let pinned = Bookmark(
            title: "Pinned",
            url: "https://pinned.example",
            isPinned: true
        )
        let hidden = Bookmark(
            title: "Hidden",
            url: "https://hidden.example",
            isHidden: true
        )
        let archived = Bookmark(
            title: "Archived",
            url: "https://archived.example",
            archivedAt: Date()
        )
        let library = ObeliskLibraryModel(
            snapshot: ObeliskLibrarySnapshot(
                bookmarks: [visible, pinned, hidden, archived]
            ),
            phase: .ready
        )

        #expect(library.bookmarks.map(\.id) == [pinned.id, visible.id])
        #expect(library.pinnedBookmarks.map(\.id) == [pinned.id])
        #expect(library.unpinnedBookmarks.map(\.id) == [visible.id])
        #expect(library.hiddenBookmarks.map(\.id) == [hidden.id])
        #expect(library.archivedBookmarks.map(\.id) == [archived.id])
    }

    @Test func searchMatchesTitleURLAndCollectionName() {
        let collection = BookmarkCollection(name: "开发资料")
        let swift = Bookmark(title: "Swift Documentation", url: "https://developer.apple.com")
        let powersync = Bookmark(title: "Offline First", url: "https://powersync.com")
        let library = ObeliskLibraryModel(
            snapshot: ObeliskLibrarySnapshot(
                bookmarks: [swift, powersync],
                collections: [collection],
                collectionByBookmarkID: [swift.id: collection.id]
            ),
            phase: .ready
        )

        #expect(library.search("Swift").map(\.id) == [swift.id])
        #expect(library.search("powersync.com").map(\.id) == [powersync.id])
        #expect(library.search("开发").map(\.id) == [swift.id])
    }

    @Test func recentTabUsesSyncedBrowserHistoryInsteadOfBookmarkUsage() {
        let bookmark = Bookmark(title: "Bookmark", url: "https://bookmark.example")
        let older = BrowserHistoryRecord(
            id: UUID(),
            title: "Older history",
            url: "https://older.example",
            visitedAt: Date(timeIntervalSince1970: 100),
            browser: .safari,
            profileName: "默认"
        )
        let newer = BrowserHistoryRecord(
            id: UUID(),
            title: "Newer history",
            url: "https://newer.example",
            visitedAt: Date(timeIntervalSince1970: 200),
            browser: .chrome,
            profileName: "默认"
        )
        let library = ObeliskLibraryModel(
            snapshot: ObeliskLibrarySnapshot(
                bookmarks: [bookmark],
                usageByBookmarkID: [
                    bookmark.id: UsageRecord(count: 4, lastClickedAt: Date())
                ],
                browserHistory: [older, newer],
                browserHistorySettings: BrowserHistorySettings(
                    enabledBrowsers: [.chrome, .safari]
                )
            ),
            phase: .ready
        )

        #expect(library.browserHistorySections.flatMap(\.records).map(\.id) == [newer.id, older.id])

        let usageOnly = ObeliskLibraryModel(
            snapshot: ObeliskLibrarySnapshot(
                bookmarks: [bookmark],
                usageByBookmarkID: [
                    bookmark.id: UsageRecord(count: 1, lastClickedAt: Date())
                ]
            ),
            phase: .ready
        )
        #expect(usageOnly.browserHistorySections.isEmpty)
    }

    @Test func recentTabFiltersHistoryUsingSyncedBrowserSelection() {
        let chrome = BrowserHistoryRecord(
            id: UUID(),
            title: "Chrome",
            url: "https://chrome.example",
            visitedAt: Date(timeIntervalSince1970: 200),
            browser: .chrome,
            profileName: "默认"
        )
        let safari = BrowserHistoryRecord(
            id: UUID(),
            title: "Safari",
            url: "https://safari.example",
            visitedAt: Date(timeIntervalSince1970: 100),
            browser: .safari,
            profileName: "Safari"
        )
        let library = ObeliskLibraryModel(
            snapshot: ObeliskLibrarySnapshot(
                browserHistory: [chrome, safari],
                browserHistorySettings: BrowserHistorySettings(enabledBrowsers: [.chrome])
            ),
            phase: .ready
        )

        #expect(library.enabledBrowserHistoryBrowsers == [.chrome])
        #expect(library.browserHistorySections.flatMap(\.records).map(\.id) == [chrome.id])
    }

    @Test func bookmarkOverviewMatchesMacSections() {
        let now = Date()
        let pinned = Bookmark(
            title: "Pinned",
            url: "https://pinned.example",
            createdAt: now,
            isPinned: true
        )
        let grouped = Bookmark(
            title: "Grouped",
            url: "https://grouped.example",
            createdAt: now.addingTimeInterval(-1)
        )
        let ungrouped = (0..<6).map { index in
            Bookmark(
                title: "Bookmark \(index)",
                url: "https://example.com/\(index)",
                createdAt: now.addingTimeInterval(TimeInterval(-index - 2))
            )
        }
        let collection = BookmarkCollection(name: "分组")
        let library = ObeliskLibraryModel(
            snapshot: ObeliskLibrarySnapshot(
                bookmarks: [pinned, grouped] + ungrouped,
                collections: [collection],
                collectionByBookmarkID: [grouped.id: collection.id]
            ),
            phase: .ready
        )

        #expect(library.pinnedBookmarks.map(\.id) == [pinned.id])
        #expect(
            library.recentlyAddedBookmarks.map(\.id)
                == [grouped.id] + ungrouped.prefix(4).map(\.id)
        )
        #expect(Set(library.ungroupedBookmarks.map(\.id)) == Set(ungrouped.map(\.id)))
    }

    @Test func bookmarkRowsHaveSectionScopedIdentity() {
        let bookmark = Bookmark(title: "Shared", url: "https://shared.example")
        let recent = BookmarkSectionItem(bookmark: bookmark, section: .recent)
        let ungrouped = BookmarkSectionItem(bookmark: bookmark, section: .ungrouped)

        #expect(recent.id != ungrouped.id)
    }

    @Test func automaticArchiveMatchesTheConfiguredIdleWindow() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: ObeliskLibraryModel.autoArchiveEnabledKey)
        let days = defaults.object(forKey: ObeliskLibraryModel.archiveAfterDaysKey)
        defer {
            restore(enabled, key: ObeliskLibraryModel.autoArchiveEnabledKey, defaults: defaults)
            restore(days, key: ObeliskLibraryModel.archiveAfterDaysKey, defaults: defaults)
        }
        defaults.set(true, forKey: ObeliskLibraryModel.autoArchiveEnabledKey)
        defaults.set(3, forKey: ObeliskLibraryModel.archiveAfterDaysKey)

        let now = Date()
        let bookmarks = (0..<7).map { index in
            Bookmark(
                title: "Bookmark \(index)",
                url: "https://example.com/\(index)",
                createdAt: now.addingTimeInterval(TimeInterval(-40 + index) * 86_400)
            )
        }
        let collection = BookmarkCollection(name: "长期资料")
        let library = ObeliskLibraryModel(
            snapshot: ObeliskLibrarySnapshot(
                bookmarks: bookmarks,
                collections: [collection],
                collectionByBookmarkID: [bookmarks[0].id: collection.id]
            ),
            phase: .ready
        )

        #expect(library.archivedBookmarks.map(\.id) == [bookmarks[1].id])
        #expect(
            Set(library.bookmarks.map(\.id))
                == Set([bookmarks[0].id] + bookmarks.dropFirst(2).map(\.id))
        )
    }

    private func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
