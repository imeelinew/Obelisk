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

    @Test func recentBookmarksUseLastOpenTime() {
        let older = Bookmark(title: "Older", url: "https://older.example")
        let newer = Bookmark(title: "Newer", url: "https://newer.example")
        let library = ObeliskLibraryModel(
            snapshot: ObeliskLibrarySnapshot(
                bookmarks: [older, newer],
                usageByBookmarkID: [
                    older.id: UsageRecord(
                        count: 4,
                        lastClickedAt: Date(timeIntervalSince1970: 100)
                    ),
                    newer.id: UsageRecord(
                        count: 1,
                        lastClickedAt: Date(timeIntervalSince1970: 200)
                    ),
                ]
            ),
            phase: .ready
        )

        #expect(library.recentlyOpenedBookmarks.map(\.id) == [newer.id, older.id])
    }
}
