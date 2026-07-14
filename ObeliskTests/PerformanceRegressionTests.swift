import Foundation
import ObeliskCore
import ObeliskData
import Testing
@testable import Obelisk

struct PerformanceRegressionTests {
    @Test func indexedPinyinSearchScalesToLargeLibraries() throws {
        let bookmarks = (0..<4_000).map { index in
            Bookmark(
                title: "哔哩哔哩 技术视频 \(index)",
                url: "https://example.com/videos/\(index)",
                originalTitle: "Bilibili Video \(index)"
            )
        }

        let clock = ContinuousClock()
        let start = clock.now
        let index = BookmarkSearchIndex(bookmarks: bookmarks)
        var matches: Set<Bookmark.ID> = []
        for query in ["bili", "blbl", "技术", "video 3999", "example.com/videos/20"] {
            matches.formUnion(index.matchingIDs(query: query))
        }
        let elapsed = start.duration(to: clock.now)

        #expect(matches.contains(bookmarks[3_999].id))
        #expect(elapsed < .seconds(10))
    }

    @Test func normalizedDatabaseRoundTripScalesToLargeLibraries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bookmarks = (0..<1_000).map { index in
            Bookmark(
                title: "Bookmark \(index)",
                url: "https://example.com/bookmarks/\(index)",
                createdAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index)),
                originalTitle: "Bookmark \(index)"
            )
        }

        let clock = ContinuousClock()
        let start = clock.now
        let store = try await BookmarkStore.open(
            rootDirectory: root,
            ownerID: UUID(),
            deviceID: UUID()
        )
        for bookmark in bookmarks {
            try store.database.saveBookmark(bookmark, collectionID: nil)
        }
        let loaded = try store.snapshot().bookmarks
        let elapsed = start.duration(to: clock.now)

        #expect(loaded.count == bookmarks.count)
        #expect(Set(loaded.map(\.id)) == Set(bookmarks.map(\.id)))
        #expect(elapsed < .seconds(10))
    }
}
