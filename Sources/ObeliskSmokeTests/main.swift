import Foundation
import ObeliskCore

struct SmokeTests {
    static func main() throws {
        try testDuplicateProtection()
        try testWebURLValidation()
        try testLegacyCreatedAtFallback()
        try testLegacyHiddenFallback()
        try testHiddenBookmarkPersistence()
        try testHiddenDuplicateProtection()
        try testBatchDelete()
        try testTitleOptimizationPersistence()
        try testUsageGroupingFilters()
        try testEncryptedBookmarkStoreRoundTrip()
        print("Obelisk smoke tests passed")
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

    private static func testWebURLValidation() throws {
        let store = BookmarkStore(rootDirectory: try temporaryDirectory())
        let trimmed = try store.add(title: "Trimmed", url: "  https://trimmed.example/path  \n")
        try expect(trimmed.url == "https://trimmed.example/path", "expected stored URL to be trimmed")

        do {
            _ = try store.add(title: "FTP", url: "ftp://example.com")
            throw SmokeTestError.failure("expected ftp URL to be rejected")
        } catch BookmarkStoreError.invalidURL {
        }

        do {
            _ = try store.add(title: "No Host", url: "https:foo")
            throw SmokeTestError.failure("expected URL without host to be rejected")
        } catch BookmarkStoreError.invalidURL {
        }

        do {
            _ = try store.add(title: "Duplicate", url: "https://trimmed.example/path")
            throw SmokeTestError.failure("expected trimmed URL duplicate to be rejected")
        } catch BookmarkStoreError.duplicateURL {
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

    private static func testLegacyHiddenFallback() throws {
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
        try expect(loaded[0].isHidden == false, "expected legacy hidden fallback to false")
    }

    private static func testHiddenBookmarkPersistence() throws {
        let store = BookmarkStore(rootDirectory: try temporaryDirectory())
        let hidden = try store.add(title: "Hidden", url: "https://hidden.example", isHidden: true)
        let visible = try store.add(title: "Visible", url: "https://visible.example")

        let loaded = try store.bookmarks()
        try expect(loaded.first { $0.id == hidden.id }?.isHidden == true, "expected hidden bookmark flag to persist")
        try expect(loaded.first { $0.id == visible.id }?.isHidden == false, "expected visible bookmark flag to default false")
    }

    private static func testHiddenDuplicateProtection() throws {
        let store = BookmarkStore(rootDirectory: try temporaryDirectory())
        _ = try store.add(title: "Visible", url: "https://duplicate.example")

        do {
            _ = try store.add(title: "Hidden Duplicate", url: "https://duplicate.example/", isHidden: true)
            throw SmokeTestError.failure("expected hidden duplicate URL to be rejected")
        } catch BookmarkStoreError.duplicateURL {
        }
    }

    private static func testBatchDelete() throws {
        let root = try temporaryDirectory()
        let store = BookmarkStore(rootDirectory: root)
        let first = try store.add(title: "First", url: "https://first.example")
        let second = try store.add(title: "Second", url: "https://second.example")
        let kept = try store.add(title: "Kept", url: "https://kept.example")

        try store.delete(ids: [first.id, second.id])

        let loaded = try store.bookmarks()
        try expect(loaded.map(\.id) == [kept.id], "expected batch delete to remove selected bookmarks only")
    }

    private static func testTitleOptimizationPersistence() throws {
        let root = try temporaryDirectory()
        let store = BookmarkStore(rootDirectory: root)
        let first = try store.add(title: "(14) Inbox | user@example.com | Proton Mail", url: "https://mail.proton.me/u/0/inbox")
        let second = try store.add(title: "Claude", url: "https://claude.ai/new")

        let count = try store.applyTitleOptimizations([
            first.id: "Proton Mail",
            second.id: "Claude"
        ])
        try expect(count == 2, "expected both unoptimized titles to be marked optimized")

        let loaded = try store.bookmarks()
        try expect(loaded.first { $0.id == first.id }?.title == "Proton Mail", "expected optimized title to persist")
        try expect(loaded.first { $0.id == first.id }?.titleOptimized == true, "expected optimized marker to persist")

        let secondPass = try store.applyTitleOptimizations([
            first.id: "Mail",
            second.id: "Claude AI"
        ])
        try expect(secondPass == 0, "expected optimized titles to be skipped on second pass")
        let reloaded = try store.bookmarks()
        try expect(reloaded.first { $0.id == first.id }?.title == "Proton Mail", "expected second pass to preserve optimized title")
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

    private static func testEncryptedBookmarkStoreRoundTrip() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        LocalJSONEncryption.isEnabled = true

        let store = BookmarkStore(rootDirectory: root)
        let bookmark = try store.add(title: "Private", url: "https://private.example")
        let raw = try Data(contentsOf: store.fileURL)
        let rawText = String(decoding: raw, as: UTF8.self)
        let legacyURL = ObeliskPrivateStorage.legacyFileURL(rootDirectory: root, logicalName: "bookmarks.json")

        try expect(rawText.contains("obelisk.encrypted-json.v1"), "expected encrypted envelope marker")
        try expect(!rawText.contains("private.example"), "expected encrypted file to hide bookmark URL")
        try expect(store.fileURL.pathExtension == "bin", "expected encrypted bookmark store to use an obscured bin file")
        try expect(!FileManager.default.fileExists(atPath: legacyURL.path), "expected encrypted bookmark store to avoid legacy filename")
        try expect(try store.bookmarks().map(\.id) == [bookmark.id], "expected encrypted bookmark to read back")

        LocalJSONEncryption.isEnabled = false
        let database = try store.load()
        try store.save(database)
        let plaintext = try String(contentsOf: store.fileURL, encoding: .utf8)
        try expect(plaintext.contains("private.example"), "expected disabled encryption to write plaintext JSON")
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskTests")
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
try SmokeTests.main()
