import Foundation
import ObeliskCore

struct SmokeTests {
    static func main() throws {
        try testDuplicateProtection()
        try testWebURLValidation()
        try testLegacyCreatedAtFallback()
        try testLegacyHiddenFallback()
        try testLegacyArchiveFallback()
        try testLegacyBookmarkStateMigration()
        try testHiddenBookmarkPersistence()
        try testArchivePersistence()
        try testStateCleanupOnDelete()
        try testHiddenDuplicateProtection()
        try testBatchDelete()
        try testTitleOptimizationPersistence()
        try testUsageGroupingFilters()
        try testEncryptedBookmarkStoreRoundTrip()
        try testEncryptedBookmarkStateStoreRoundTrip()
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

    private static func testLegacyArchiveFallback() throws {
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
        try expect(loaded[0].archivedAt == nil, "expected legacy archivedAt fallback to nil")
    }

    private static func testLegacyBookmarkStateMigration() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("bookmarks.json")
        try """
        {
          "version": 1,
          "bookmarks": [
            {
              "id": "00000000-0000-0000-0000-000000000101",
              "title": "Legacy State",
              "url": "https://legacy-state.example",
              "createdAt": "1970-01-01T00:01:40Z",
              "titleOptimized": true,
              "isHidden": true,
              "archivedAt": "1970-01-01T00:03:20Z"
            }
          ]
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = BookmarkStore(rootDirectory: root)
        let loaded = try store.bookmarks()
        let id = try expectUUID("00000000-0000-0000-0000-000000000101")

        try expect(loaded.count == 1, "expected migrated bookmark to load")
        try expect(loaded[0].id == id, "expected migrated bookmark id to be preserved")
        try expect(loaded[0].title == "Legacy State", "expected migrated title to be preserved")
        try expect(loaded[0].url == "https://legacy-state.example", "expected migrated URL to be preserved")
        try expect(loaded[0].isHidden == true, "expected legacy hidden flag to move into state")
        try expect(loaded[0].titleOptimized == true, "expected legacy title optimization flag to move into state")
        try expect(loaded[0].createdAt == Date(timeIntervalSince1970: 100), "expected legacy createdAt to move into state")
        try expect(loaded[0].archivedAt == nil, "expected legacy archivedAt to be discarded")

        let state = BookmarkStateStore(rootDirectory: root).load()
        try expect(state.hiddenIds == [id], "expected hidden id in bookmark_state")
        try expect(state.titleOptimizedIds == [id], "expected title optimized id in bookmark_state")
        try expect(state.createdAtById[id] == Date(timeIntervalSince1970: 100), "expected createdAt in bookmark_state")
        try expect(state.manualArchivedIds.isEmpty, "expected legacy archivedAt not to become manual archive state")

        try store.save(try store.load())
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        try expectBookmarkJSONContainsOnlyCoreFields(raw)
    }

    private static func testHiddenBookmarkPersistence() throws {
        let store = BookmarkStore(rootDirectory: try temporaryDirectory())
        let hidden = try store.add(title: "Hidden", url: "https://hidden.example", isHidden: true)
        let visible = try store.add(title: "Visible", url: "https://visible.example")

        let loaded = try store.bookmarks()
        try expect(loaded.first { $0.id == hidden.id }?.isHidden == true, "expected hidden bookmark flag to persist")
        try expect(loaded.first { $0.id == visible.id }?.isHidden == false, "expected visible bookmark flag to default false")
    }

    private static func testArchivePersistence() throws {
        let store = BookmarkStore(rootDirectory: try temporaryDirectory())
        let bookmark = try store.add(title: "Archive", url: "https://archive.example")
        let archivedAt = Date(timeIntervalSince1970: 123)

        try store.setArchived(true, ids: [bookmark.id], at: archivedAt)
        var loaded = try store.bookmarks()
        try expect(loaded.first { $0.id == bookmark.id }?.archivedAt != nil, "expected manual archive state to persist")
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        try expect(!raw.contains("archivedAt"), "expected bookmark JSON to omit archivedAt state")
        var state = BookmarkStateStore(rootDirectory: store.rootDirectory).load()
        try expect(state.manualArchivedIds == [bookmark.id], "expected manual archive id in bookmark_state")

        try store.setArchived(false, ids: [bookmark.id])
        loaded = try store.bookmarks()
        try expect(loaded.first { $0.id == bookmark.id }?.archivedAt == nil, "expected archive restore to clear archivedAt")
        state = BookmarkStateStore(rootDirectory: store.rootDirectory).load()
        try expect(state.manualArchivedIds.isEmpty, "expected restore to clear manual archive id")
    }

    private static func testStateCleanupOnDelete() throws {
        let root = try temporaryDirectory()
        let store = BookmarkStore(rootDirectory: root)
        let bookmark = try store.add(title: "Delete Me", url: "https://delete-me.example", isHidden: true)

        try store.setArchived(true, ids: [bookmark.id])
        _ = try store.applyTitleOptimizations([bookmark.id: "Deleted"])
        var state = BookmarkStateStore(rootDirectory: root).load()
        try expect(state.hiddenIds.contains(bookmark.id), "expected hidden state before delete")
        try expect(state.manualArchivedIds.contains(bookmark.id), "expected archive state before delete")
        try expect(state.titleOptimizedIds.contains(bookmark.id), "expected title state before delete")
        try expect(state.createdAtById[bookmark.id] != nil, "expected createdAt state before delete")

        try store.delete(id: bookmark.id)
        state = BookmarkStateStore(rootDirectory: root).load()
        try expect(!state.hiddenIds.contains(bookmark.id), "expected delete to clean hidden state")
        try expect(!state.manualArchivedIds.contains(bookmark.id), "expected delete to clean archive state")
        try expect(!state.titleOptimizedIds.contains(bookmark.id), "expected delete to clean title optimization state")
        try expect(state.createdAtById[bookmark.id] == nil, "expected delete to clean createdAt state")
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

    private static func testEncryptedBookmarkStateStoreRoundTrip() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        LocalJSONEncryption.isEnabled = true

        let store = BookmarkStore(rootDirectory: root)
        let bookmark = try store.add(title: "State Private", url: "https://state-private.example", isHidden: true)
        try store.setArchived(true, ids: [bookmark.id])
        _ = try store.applyTitleOptimizations([bookmark.id: "State Private Optimized"])

        let stateStore = BookmarkStateStore(rootDirectory: root)
        let stateURL = stateStore.fileURL
        let legacyURL = ObeliskPrivateStorage.legacyFileURL(rootDirectory: root, logicalName: "bookmark_state.json")
        let raw = try Data(contentsOf: stateURL)
        let rawText = String(decoding: raw, as: UTF8.self)

        try expect(stateURL.pathExtension == "bin", "expected encrypted bookmark state to use an obscured bin file")
        try expect(!FileManager.default.fileExists(atPath: legacyURL.path), "expected encrypted state to avoid legacy filename")
        try expect(rawText.contains("obelisk.encrypted-json.v1"), "expected encrypted state envelope marker")
        try expect(!rawText.contains(bookmark.id.uuidString), "expected encrypted state to hide bookmark id")
        try expect(!rawText.contains("state-private.example"), "expected encrypted state to hide bookmark URL")
        try expect(!rawText.contains("State Private"), "expected encrypted state to hide bookmark title")

        let state = stateStore.load()
        try expect(state.hiddenIds == [bookmark.id], "expected encrypted state to read hidden id")
        try expect(state.manualArchivedIds == [bookmark.id], "expected encrypted state to read archive id")
        try expect(state.titleOptimizedIds == [bookmark.id], "expected encrypted state to read title optimized id")
        try expect(state.createdAtById[bookmark.id] != nil, "expected encrypted state to read createdAt")
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

    private static func expectUUID(_ raw: String) throws -> UUID {
        guard let id = UUID(uuidString: raw) else {
            throw SmokeTestError.failure("invalid test UUID: \(raw)")
        }
        return id
    }

    private static func expectBookmarkJSONContainsOnlyCoreFields(_ raw: String) throws {
        for forbidden in ["archivedAt", "isHidden", "titleOptimized", "createdAt"] {
            try expect(!raw.contains(forbidden), "expected bookmark JSON to omit \(forbidden)")
        }
        for required in ["id", "title", "url"] {
            try expect(raw.contains(required), "expected bookmark JSON to contain \(required)")
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
