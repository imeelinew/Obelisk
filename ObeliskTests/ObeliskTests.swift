import AppKit
import Foundation
import ObeliskCore
import ObeliskData
import Testing
@testable import Obelisk

@Suite(.serialized)
struct ObeliskTests {
    @MainActor
    @Test func normalizedDatabasePersistsBookmarkState() async throws {
        try await withStore { store in
            var bookmark = try store.add(title: " Example ", url: "https://example.com/")
            #expect(bookmark.title == "Example")

            bookmark.isHidden = true
            bookmark = try store.update(bookmark)
            let loaded = try #require(store.snapshot().bookmarks.first)
            #expect(loaded.id == bookmark.id)
            #expect(loaded.isHidden)
            #expect(loaded.titleOptimizationState == .notAttempted)

            try store.delete(ids: [bookmark.id])
            #expect(try store.snapshot().bookmarks.isEmpty)
        }
    }

    @MainActor
    @Test func normalizedURLPreventsDuplicates() async throws {
        try await withStore { store in
            _ = try store.add(title: "First", url: "HTTPS://Example.COM:443/path/?b=2&a=1#fragment")
            #expect(throws: BookmarkStoreError.self) {
                try store.add(title: "Duplicate", url: "https://example.com/path?a=1&b=2")
            }
        }
    }

    @MainActor
    @Test func collectionsAndUsageShareTheSameDatabase() async throws {
        try await withStore { store in
            let bookmark = try store.add(title: "Article", url: "https://example.com/article")
            let collection = BookmarkCollection(name: "Reading")
            try store.database.saveCollection(collection)
            try store.database.setCollection(collection.id, for: [bookmark.id])
            try store.database.recordUsage(bookmarkID: bookmark.id, at: Date(timeIntervalSince1970: 100))
            try store.database.recordUsage(bookmarkID: bookmark.id, at: Date(timeIntervalSince1970: 200))

            var snapshot = try store.snapshot()
            #expect(snapshot.collections == [collection])
            #expect(snapshot.collectionByBookmarkID[bookmark.id] == collection.id)
            #expect(snapshot.usageByBookmarkID[bookmark.id]?.count == 2)
            #expect(snapshot.usageByBookmarkID[bookmark.id]?.lastClickedAt == Date(timeIntervalSince1970: 200))

            try store.database.deleteCollection(id: collection.id)
            snapshot = try store.snapshot()
            #expect(snapshot.collections.isEmpty)
            #expect(snapshot.collectionByBookmarkID[bookmark.id] == nil)
        }
    }

    @MainActor
    @Test func modelSearchExcludesHiddenAndArchivedBookmarks() async throws {
        try await withStore { store in
            let visible = try store.add(title: "Target visible", url: "https://visible.example")
            _ = try store.add(title: "Target hidden", url: "https://hidden.example", isHidden: true)
            let archived = try store.add(title: "Target archived", url: "https://archived.example")
            try store.setArchived(true, ids: [archived.id], at: Date(timeIntervalSince1970: 1_000))

            let model = BookmarksModel(store: store)
            #expect(model.searchBookmarks(matching: "target").map(\.id) == [visible.id])
        }
    }

    @MainActor
    @Test func modelCreatesMovesAndDeletesCollections() async throws {
        try await withStore { store in
            let bookmark = try store.add(title: "Swift", url: "https://swift.org")
            let model = BookmarksModel(store: store)

            #expect(model.createCollection(name: "Development") == nil)
            let collection = try #require(model.collections.first)
            #expect(model.setBookmarkCollection(bookmarkId: bookmark.id, collectionId: collection.id) == nil)
            #expect(model.collectionId(for: bookmark.id) == collection.id)
            #expect(model.deleteCollection(id: collection.id) == nil)
            #expect(model.collectionId(for: bookmark.id) == nil)
        }
    }

    @Test func frecencySortingIsDeterministic() {
        let first = Bookmark(title: "Zulu", url: "https://z.example")
        let second = Bookmark(title: "Alpha", url: "https://a.example")
        let now = Date(timeIntervalSince1970: 10_000)
        let usage = [
            first.id: UsageRecord(count: 5, lastClickedAt: now.addingTimeInterval(-86_400)),
            second.id: UsageRecord(count: 5, lastClickedAt: now)
        ]

        #expect(BookmarkUsageRanking.frecencySorted(among: [first, second], usage: usage, now: now).map(\.id) == [second.id, first.id])
    }

    @Test func menuOrderUsesSyncedCollectionOrderBetweenFixedScopes() {
        let current = BookmarkCollection(name: "Current")

        #expect(
            BookmarkMenuSectionOrder.order(collections: [current]) == [
                .recent,
                .collection(current.id),
                .ungrouped
            ]
        )
    }

    @Test func menuExpansionDefaultsToRecentAndCommonOnly() throws {
        let suite = "ObeliskMenuExpansion-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let common = BookmarkCollection(name: "常用")
        let other = BookmarkCollection(name: "Other")
        #expect(BookmarkMenuExpansionPreferences.expandedIDs(
            collections: [common, other],
            defaults: defaults
        ) == [.recent, .collection(common.id)])
    }

    @MainActor
    @Test func appDelegateLeavesDockReopenToAppKit() {
        #expect(!AppDelegate.instancesRespond(to: #selector(
            NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)
        )))
    }

    @MainActor
    private func withStore(
        _ body: @MainActor (BookmarkStore) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await BookmarkStore.open(
            rootDirectory: root,
            deviceID: UUID()
        )
        try await body(store)
    }
}
