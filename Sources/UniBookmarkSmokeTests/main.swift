import Foundation
import UniBookmarkCore

@main
struct SmokeTests {
    static func main() throws {
        try testDuplicateProtection()
        try testLegacyCreatedAtFallback()
        try testUsageGroupingFilters()
        print("UniBookmark smoke tests passed")
    }

    private static func testDuplicateProtection() throws {
        let store = BookmarkStore(rootDirectory: try temporaryDirectory())
        let added = try store.add(title: "Example", url: "https://Example.com:443/")
        try expect(added.title == "Example", "expected added bookmark title to be preserved")
        do {
            _ = try store.add(title: "Duplicate", url: "https://example.com")
            throw SmokeTestError.failure("expected normalized duplicate URL to be rejected")
        } catch BookmarkStoreError.duplicateURL {
            return
        }
    }

    private static func testLegacyCreatedAtFallback() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("bookmarks.json")
        try """
        {
          "version": 1,
          "bookmarks": [
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "title": "Old",
              "url": "https://example.com"
            }
          ]
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let loaded = try BookmarkStore(rootDirectory: root).bookmarks()
        try expect(loaded.count == 1, "expected one legacy bookmark")
        try expect(loaded[0].createdAt == .distantPast, "expected legacy createdAt fallback")
    }

    private static func testUsageGroupingFilters() throws {
        let root = try temporaryDirectory()
        let usageStore = UsageStore(rootDirectory: root)
        let frequent = Bookmark(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Frequent",
            url: "https://frequent.example",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let lowCount = Bookmark(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "Low",
            url: "https://low.example",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let legacy = Bookmark(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            title: "Legacy",
            url: "https://legacy.example",
            createdAt: .distantPast
        )

        usageStore.record(id: frequent.id)
        usageStore.record(id: frequent.id)
        usageStore.record(id: frequent.id)
        usageStore.record(id: lowCount.id)

        let bookmarks = [frequent, lowCount, legacy]
        try expect(
            usageStore.topFrequent(among: bookmarks, limit: 5).map(\.id) == [frequent.id],
            "expected only count >= 3 bookmark in frequent group"
        )
        try expect(
            usageStore.recent(among: bookmarks, limit: 5).map(\.id) == [lowCount.id, frequent.id],
            "expected recent group to skip legacy dates"
        )
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniBookmarkTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw SmokeTestError.failure(message)
        }
    }
}

private enum SmokeTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message):
            return message
        }
    }
}
