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
        try testUsageStoreCacheInvalidation()
        try testBookmarkStoreCacheInvalidation()
        try testStorageNormalizeMigratesSingleStaleJSONFile()
        try testStorageNormalizeRemovesDuplicateJSONFile()
        try testStorageNormalizeMigratesLegacyRootJSONFile()
        try testPlaintextStorageUsesDataDirectory()
        try testStorageNormalizeRemovesEmptyLegacyDirectories()
        try testStorageNormalizeDecryptsMixedICloudLikeFaviconState()
        try testStorageNormalizeEncryptsMixedICloudLikeFaviconState()
        try testStorageNormalizeDecryptsMixedJSONAndFaviconState()
        try testStorageNormalizeEncryptsMixedJSONAndFaviconState()
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
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        try expectBookmarkJSONContainsOnlyCoreFields(raw)
        try expect(!FileManager.default.fileExists(atPath: fileURL.path), "expected legacy root bookmark JSON to be removed")
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

    private static func testUsageStoreCacheInvalidation() throws {
        let root = try temporaryDirectory()
        let store = UsageStore(rootDirectory: root)
        let id = try expectUUID("00000000-0000-0000-0000-000000000201")
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)

        store.saveAll([id: UsageRecord(count: 1, lastClickedAt: firstDate)])
        try expect(store.record(for: id)?.count == 1, "expected initial usage count")

        let fileURL = ObeliskPrivateStorage.legacyFileURL(rootDirectory: root, logicalName: "usage.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {
          "\(id.uuidString)" : {
            "count" : 2,
            "lastClickedAt" : "1970-01-01T00:03:20Z"
          }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        try expect(store.record(for: id)?.count == 1, "expected cached usage before invalidation")
        store.invalidateCache()
        let reloaded = store.record(for: id)
        try expect(reloaded?.count == 2, "expected usage count after invalidation")
        try expect(reloaded?.lastClickedAt == secondDate, "expected usage date after invalidation")

        store.updateRootDirectory(try temporaryDirectory())
        try expect(store.record(for: id) == nil, "expected root change to clear usage cache")
    }

    private static func testBookmarkStoreCacheInvalidation() throws {
        let root = try temporaryDirectory()
        let store = BookmarkStore(rootDirectory: root)
        let bookmark = try store.add(title: "Cached", url: "https://cached.example")
        try expect(try store.bookmarks().map(\.title) == ["Cached"], "expected initial cached bookmark")

        let fileURL = ObeliskPrivateStorage.legacyFileURL(rootDirectory: root, logicalName: "bookmarks.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {
          "version": 1,
          "bookmarks": [
            {
              "id": "\(bookmark.id.uuidString)",
              "title": "Externally Edited",
              "url": "https://cached.example"
            }
          ]
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        try expect(try store.bookmarks().map(\.title) == ["Cached"], "expected cached bookmark before invalidation")
        store.invalidateCache()
        try expect(try store.bookmarks().map(\.title) == ["Externally Edited"], "expected bookmark reload after invalidation")

        let newRoot = try temporaryDirectory()
        store.updateRootDirectory(newRoot)
        try expect(try store.bookmarks().isEmpty, "expected root change to clear bookmark cache")
    }

    private static func testStorageNormalizeMigratesSingleStaleJSONFile() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        let legacyURL = ObeliskPrivateStorage.legacyFileURL(rootDirectory: root, logicalName: "bookmarks.json")
        let privateURL = ObeliskPrivateStorage.privateFileURL(rootDirectory: root, logicalName: "bookmarks.json")
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {
          "version": 1,
          "bookmarks": [
            {
              "id": "00000000-0000-0000-0000-000000000301",
              "title": "Normalize",
              "url": "https://normalize.example"
            }
          ]
        }
        """.write(to: legacyURL, atomically: true, encoding: .utf8)

        try ObeliskStorageMigrator.normalizeJSONFiles(in: root, encrypted: true, logicalNames: ["bookmarks.json"])

        try expect(!FileManager.default.fileExists(atPath: legacyURL.path), "expected plaintext source to be removed")
        try expect(FileManager.default.fileExists(atPath: privateURL.path), "expected encrypted destination to exist")
        let rawText = try String(contentsOf: privateURL, encoding: .utf8)
        try expect(rawText.contains("obelisk.encrypted-json.v1"), "expected encrypted destination envelope")

        LocalJSONEncryption.isEnabled = true
        let loaded = try BookmarkStore(rootDirectory: root).bookmarks()
        try expect(loaded.map(\.url) == ["https://normalize.example"], "expected migrated encrypted bookmark to load")
    }

    private static func testStorageNormalizeRemovesDuplicateJSONFile() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        let legacyURL = ObeliskPrivateStorage.legacyFileURL(rootDirectory: root, logicalName: "usage.json")
        let privateURL = ObeliskPrivateStorage.privateFileURL(rootDirectory: root, logicalName: "usage.json")
        let olderUsage = """
        {
          "00000000-0000-0000-0000-000000000302" : {
            "count" : 4,
            "lastClickedAt" : "1970-01-01T00:05:00Z"
          }
        }
        """
        let newerUsage = """
        {
          "00000000-0000-0000-0000-000000000302" : {
            "count" : 7,
            "lastClickedAt" : "1970-01-01T00:06:00Z"
          }
        }
        """
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try olderUsage.write(to: legacyURL, atomically: true, encoding: .utf8)
        try SecureJSONFileCodec().writeData(Data(newerUsage.utf8), to: privateURL, encrypted: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: legacyURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: privateURL.path
        )

        try ObeliskStorageMigrator.normalizeJSONFiles(in: root, encrypted: false, logicalNames: ["usage.json"])

        try expect(FileManager.default.fileExists(atPath: legacyURL.path), "expected plaintext target to remain")
        try expect(!FileManager.default.fileExists(atPath: privateURL.path), "expected encrypted duplicate to be removed")
        LocalJSONEncryption.isEnabled = false
        let id = try expectUUID("00000000-0000-0000-0000-000000000302")
        try expect(UsageStore(rootDirectory: root).record(for: id)?.count == 7, "expected newest duplicate usage to win")
    }

    private static func testStorageNormalizeMigratesLegacyRootJSONFile() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        let legacyRootURL = ObeliskPrivateStorage.legacyRootFileURL(
            rootDirectory: root,
            logicalName: "bookmarks.json"
        )
        let dataURL = ObeliskPrivateStorage.legacyFileURL(rootDirectory: root, logicalName: "bookmarks.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        {
          "version": 1,
          "bookmarks": [
            {
              "id": "00000000-0000-0000-0000-000000000303",
              "title": "Legacy Root",
              "url": "https://legacy-root.example"
            }
          ]
        }
        """.write(to: legacyRootURL, atomically: true, encoding: .utf8)

        try ObeliskStorageMigrator.normalizeJSONFiles(in: root, encrypted: false, logicalNames: ["bookmarks.json"])

        try expect(FileManager.default.fileExists(atPath: dataURL.path), "expected legacy root JSON to move into Data")
        try expect(!FileManager.default.fileExists(atPath: legacyRootURL.path), "expected legacy root JSON to be removed")
        LocalJSONEncryption.isEnabled = false
        try expect(
            try BookmarkStore(rootDirectory: root).bookmarks().map(\.url) == ["https://legacy-root.example"],
            "expected migrated Data bookmark to load"
        )
    }

    private static func testPlaintextStorageUsesDataDirectory() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        LocalJSONEncryption.isEnabled = false
        let store = BookmarkStore(rootDirectory: root)
        _ = try store.add(title: "Plain", url: "https://plain.example")

        let dataURL = ObeliskPrivateStorage.legacyFileURL(rootDirectory: root, logicalName: "bookmarks.json")
        let rootURL = ObeliskPrivateStorage.legacyRootFileURL(rootDirectory: root, logicalName: "bookmarks.json")
        try expect(store.fileURL == dataURL, "expected plaintext active file to live in Data")
        try expect(FileManager.default.fileExists(atPath: dataURL.path), "expected plaintext bookmark JSON in Data")
        try expect(!FileManager.default.fileExists(atPath: rootURL.path), "expected no root-level plaintext bookmark JSON")
    }

    private static func testStorageNormalizeRemovesEmptyLegacyDirectories() throws {
        let root = try temporaryDirectory()
        let emptyDirectories = [
            ObeliskPrivateStorage.legacyFaviconDirectory(in: root),
            ObeliskPrivateStorage.legacyEncryptedFaviconDirectory(in: root),
            ObeliskPrivateStorage.legacyEncryptedDataDirectory(in: root),
            ObeliskPrivateStorage.dataDirectory(in: root)
        ]
        for directory in emptyDirectories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let encryptedData = ObeliskPrivateStorage.encryptedDataDirectory(in: root)
        try FileManager.default.createDirectory(at: encryptedData, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: encryptedData.appendingPathComponent("keep.bin"))

        ObeliskStorageMigrator.removeEmptyStorageDirectories(in: root)

        for directory in emptyDirectories {
            try expect(!FileManager.default.fileExists(atPath: directory.path), "expected empty storage directory to be removed: \(directory.path)")
        }
        try expect(FileManager.default.fileExists(atPath: encryptedData.path), "expected non-empty storage directory to remain")
    }

    private static func testStorageNormalizeDecryptsMixedICloudLikeFaviconState() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        let key = "1234abcd"
        let encryptedIndexURL = ObeliskPrivateStorage.faviconIndexURL(rootDirectory: root, encrypted: true)
        let encryptedIconURL = ObeliskPrivateStorage.faviconIconURL(rootDirectory: root, key: key, encrypted: true)
        let plaintextIndexURL = ObeliskPrivateStorage.faviconIndexURL(rootDirectory: root, encrypted: false)
        let plaintextIconURL = ObeliskPrivateStorage.faviconIconURL(rootDirectory: root, key: key, encrypted: false)

        try FileManager.default.createDirectory(
            at: encryptedIndexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let index = faviconIndexJSON(key: key, fetchedAt: "1970-01-01T00:10:00Z")
        try SecureJSONFileCodec().writeData(Data(index.utf8), to: encryptedIndexURL, encrypted: true)
        try SecureJSONFileCodec().writeData(Data("encrypted-icon".utf8), to: encryptedIconURL, encrypted: true)
        try ObeliskStorageMigrator.normalizeStorage(in: root, encrypted: false)

        try expect(FileManager.default.fileExists(atPath: plaintextIndexURL.path), "expected plaintext favicon index")
        try expect(FileManager.default.fileExists(atPath: plaintextIconURL.path), "expected plaintext favicon icon")
        try expect(!FileManager.default.fileExists(atPath: ObeliskPrivateStorage.encryptedDataDirectory(in: root).path), "expected encrypted directory to be removed after decrypting")
        let icon = try String(contentsOf: plaintextIconURL, encoding: .utf8)
        try expect(icon == "encrypted-icon", "expected decrypted favicon data")
    }

    private static func testStorageNormalizeEncryptsMixedICloudLikeFaviconState() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        let key = "5678abcd"
        let plaintextIndexURL = ObeliskPrivateStorage.faviconIndexURL(rootDirectory: root, encrypted: false)
        let plaintextIconURL = ObeliskPrivateStorage.faviconIconURL(rootDirectory: root, key: key, encrypted: false)
        let encryptedIndexURL = ObeliskPrivateStorage.faviconIndexURL(rootDirectory: root, encrypted: true)
        let encryptedIconURL = ObeliskPrivateStorage.faviconIconURL(rootDirectory: root, key: key, encrypted: true)

        try FileManager.default.createDirectory(
            at: plaintextIndexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try faviconIndexJSON(key: key, fetchedAt: "1970-01-01T00:20:00Z")
            .write(to: plaintextIndexURL, atomically: true, encoding: .utf8)
        try "plain-icon".write(to: plaintextIconURL, atomically: true, encoding: .utf8)
        try ObeliskStorageMigrator.normalizeStorage(in: root, encrypted: true)

        try expect(FileManager.default.fileExists(atPath: encryptedIndexURL.path), "expected encrypted favicon index")
        try expect(FileManager.default.fileExists(atPath: encryptedIconURL.path), "expected encrypted favicon icon")
        try expect(!FileManager.default.fileExists(atPath: ObeliskPrivateStorage.dataDirectory(in: root).path), "expected plaintext data directory to be removed after encrypting")
        let raw = try String(contentsOf: encryptedIconURL, encoding: .utf8)
        try expect(raw.contains("obelisk.encrypted-json.v1"), "expected encrypted favicon payload envelope")
        let decrypted = try SecureJSONFileCodec().readData(from: encryptedIconURL)
        try expect(String(decoding: decrypted, as: UTF8.self) == "plain-icon", "expected encrypted favicon data to decrypt")
    }

    private static func testStorageNormalizeDecryptsMixedJSONAndFaviconState() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        let key = "1111abcd"
        let bookmarkURL = ObeliskPrivateStorage.fileURL(
            rootDirectory: root,
            logicalName: "bookmarks.json",
            encrypted: false
        )
        let stateURL = ObeliskPrivateStorage.fileURL(
            rootDirectory: root,
            logicalName: "bookmark_state.json",
            encrypted: false
        )
        let usageURL = ObeliskPrivateStorage.fileURL(
            rootDirectory: root,
            logicalName: "usage.json",
            encrypted: false
        )
        let encryptedIndexURL = ObeliskPrivateStorage.faviconIndexURL(rootDirectory: root, encrypted: true)
        let encryptedIconURL = ObeliskPrivateStorage.faviconIconURL(rootDirectory: root, key: key, encrypted: true)

        try FileManager.default.createDirectory(at: bookmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          "version": 1,
          "bookmarks": [
            {
              "id": "00000000-0000-0000-0000-000000000304",
              "title": "Mixed Plain",
              "url": "https://mixed-plain.example"
            }
          ]
        }
        """.write(to: bookmarkURL, atomically: true, encoding: .utf8)
        try """
        {
          "version" : 1,
          "hiddenIds" : [],
          "manualArchivedIds" : [],
          "createdAtById" : {},
          "titleOptimizedIds" : []
        }
        """.write(to: stateURL, atomically: true, encoding: .utf8)
        try "{}".write(to: usageURL, atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: encryptedIndexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SecureJSONFileCodec().writeData(
            Data(faviconIndexJSON(key: key, fetchedAt: "1970-01-01T00:30:00Z").utf8),
            to: encryptedIndexURL,
            encrypted: true
        )
        try SecureJSONFileCodec().writeData(Data("encrypted-mixed-icon".utf8), to: encryptedIconURL, encrypted: true)

        try ObeliskStorageMigrator.normalizeStorage(in: root, encrypted: false)

        let plaintextIconURL = ObeliskPrivateStorage.faviconIconURL(rootDirectory: root, key: key, encrypted: false)
        try expect(FileManager.default.fileExists(atPath: bookmarkURL.path), "expected plaintext bookmark JSON to remain in Data")
        try expect(FileManager.default.fileExists(atPath: stateURL.path), "expected plaintext state JSON to remain in Data")
        try expect(FileManager.default.fileExists(atPath: usageURL.path), "expected plaintext usage JSON to remain in Data")
        try expect(FileManager.default.fileExists(atPath: plaintextIconURL.path), "expected encrypted favicon to move into plaintext Data/Favicons")
        try expect(!FileManager.default.fileExists(atPath: ObeliskPrivateStorage.encryptedDataDirectory(in: root).path), "expected no encrypted directory after plaintext normalization")
        try expect(!FileManager.default.fileExists(atPath: ObeliskPrivateStorage.legacyRootFileURL(rootDirectory: root, logicalName: "bookmarks.json").path), "expected no root-level plaintext JSON")
    }

    private static func testStorageNormalizeEncryptsMixedJSONAndFaviconState() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        let key = "2222abcd"
        let encryptedBookmarkURL = ObeliskPrivateStorage.fileURL(
            rootDirectory: root,
            logicalName: "bookmarks.json",
            encrypted: true
        )
        let encryptedStateURL = ObeliskPrivateStorage.fileURL(
            rootDirectory: root,
            logicalName: "bookmark_state.json",
            encrypted: true
        )
        let encryptedUsageURL = ObeliskPrivateStorage.fileURL(
            rootDirectory: root,
            logicalName: "usage.json",
            encrypted: true
        )
        let plaintextIndexURL = ObeliskPrivateStorage.faviconIndexURL(rootDirectory: root, encrypted: false)
        let plaintextIconURL = ObeliskPrivateStorage.faviconIconURL(rootDirectory: root, key: key, encrypted: false)

        try FileManager.default.createDirectory(at: encryptedBookmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SecureJSONFileCodec().writeData(
            Data("""
            {
              "version": 1,
              "bookmarks": [
                {
                  "id": "00000000-0000-0000-0000-000000000305",
                  "title": "Mixed Private",
                  "url": "https://mixed-private.example"
                }
              ]
            }
            """.utf8),
            to: encryptedBookmarkURL,
            encrypted: true
        )
        try SecureJSONFileCodec().writeData(
            Data("""
            {
              "version" : 1,
              "hiddenIds" : [],
              "manualArchivedIds" : [],
              "createdAtById" : {},
              "titleOptimizedIds" : []
            }
            """.utf8),
            to: encryptedStateURL,
            encrypted: true
        )
        try SecureJSONFileCodec().writeData(Data("{}".utf8), to: encryptedUsageURL, encrypted: true)

        try FileManager.default.createDirectory(at: plaintextIndexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try faviconIndexJSON(key: key, fetchedAt: "1970-01-01T00:40:00Z")
            .write(to: plaintextIndexURL, atomically: true, encoding: .utf8)
        try "plain-mixed-icon".write(to: plaintextIconURL, atomically: true, encoding: .utf8)

        try ObeliskStorageMigrator.normalizeStorage(in: root, encrypted: true)

        let encryptedIconURL = ObeliskPrivateStorage.faviconIconURL(rootDirectory: root, key: key, encrypted: true)
        try expect(FileManager.default.fileExists(atPath: encryptedBookmarkURL.path), "expected encrypted bookmark JSON to remain in EncryptedData")
        try expect(FileManager.default.fileExists(atPath: encryptedStateURL.path), "expected encrypted state JSON to remain in EncryptedData")
        try expect(FileManager.default.fileExists(atPath: encryptedUsageURL.path), "expected encrypted usage JSON to remain in EncryptedData")
        try expect(FileManager.default.fileExists(atPath: encryptedIconURL.path), "expected plaintext favicon to move into encrypted EncryptedData/Favicons")
        try expect(!FileManager.default.fileExists(atPath: ObeliskPrivateStorage.dataDirectory(in: root).path), "expected no plaintext Data directory after encrypted normalization")
        let decrypted = try SecureJSONFileCodec().readData(from: encryptedIconURL)
        try expect(String(decoding: decrypted, as: UTF8.self) == "plain-mixed-icon", "expected encrypted mixed favicon data to decrypt")
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
        try expect(store.fileURL.deletingLastPathComponent().lastPathComponent == "EncryptedData", "expected encrypted bookmark store to use EncryptedData")
        try expect(!FileManager.default.fileExists(atPath: legacyURL.path), "expected encrypted bookmark store to avoid legacy filename")
        try expect(try store.bookmarks().map(\.id) == [bookmark.id], "expected encrypted bookmark to read back")

        LocalJSONEncryption.isEnabled = false
        let database = try store.load()
        try store.save(database)
        let plaintext = try String(contentsOf: store.fileURL, encoding: .utf8)
        try expect(plaintext.contains("private.example"), "expected disabled encryption to write plaintext JSON")
        try expect(!FileManager.default.fileExists(atPath: ObeliskPrivateStorage.privateFileURL(rootDirectory: root, logicalName: "bookmarks.json").path), "expected plaintext save to remove encrypted duplicate")
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

    private static func faviconIndexJSON(key: String, fetchedAt: String) -> String {
        """
        {
          "\(key)" : {
            "fetchedAt" : "\(fetchedAt)",
            "success" : true
          }
        }
        """
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
