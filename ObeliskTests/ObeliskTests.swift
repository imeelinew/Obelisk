import CryptoKit
import Foundation
import Security
import Testing
@testable import Obelisk

struct SmokeTests {
    @MainActor
    static func main() async throws {
        let isolatedHome = try temporaryDirectory()
        setenv("UNIBOOKMARK_HOME", isolatedHome.path, 1)
        LocalJSONEncryption.isEnabled = false
        defer {
            unsetenv("UNIBOOKMARK_HOME")
            LocalJSONEncryption.isEnabled = false
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        try testDuplicateProtection()
        try testWebURLValidation()
        try testLegacyCreatedAtFallback()
        try testLegacyHiddenFallback()
        try testLegacyArchiveFallback()
        try testLegacyBookmarkStateMigration()
        try testHiddenBookmarkPersistence()
        try testArchivePersistence()
        try testPinnedBookmarkPersistence()
        try testPinnedClearedByHiddenAndArchive()
        try testStateCleanupOnDelete()
        try testEmptyBookmarkLoadDoesNotEraseExistingState()
        try testUsageStoreCacheInvalidation()
        try testBookmarkStoreCacheInvalidation()
        try testStorageNormalizeMigratesSingleStaleJSONFile()
        try testStorageNormalizeRemovesDuplicateJSONFile()
        try testStorageNormalizeKeepsBookmarksWhenNewerEmptyDuplicateExists()
        try testStorageNormalizeAllowsIntentionalEmptyBookmarkDatabase()
        try testStorageNormalizeMigratesLegacyRootJSONFile()
        try testStorageNormalizeMigratesLegacyPrivateDataBackup()
        try testPlaintextStorageUsesDataDirectory()
        try testStorageNormalizeRemovesEmptyLegacyDirectories()
        try testStorageNormalizeDecryptsMixedFaviconState()
        try testStorageNormalizeEncryptsMixedFaviconState()
        try testStorageNormalizeDecryptsMixedJSONAndFaviconState()
        try testStorageNormalizeEncryptsMixedJSONAndFaviconState()
        try testHiddenDuplicateProtection()
        try testBatchDelete()
        try testTitleOptimizationPersistence()
        try testTitleOptimizationPreferences()
        try await testBookmarksModelFiltersHiddenTitleOptimization()
        try testUsageGroupingFilters()
        try testEncryptedBookmarkStoreRoundTrip()
        try testEncryptedBookmarkStateStoreRoundTrip()
        try testEncryptionNormalizationPreservesBookmarksStateAndUsage()
        try testBookmarkGroupsEncryptionRoundTrip()
        try testBookmarkCollectionMembership()
        try testEncryptionKeyRefusesOverwrite()
        try testEncryptionKeyMissingWhenEncryptedPayloadsExist()
        try testStorageNormalizeStopsWhenEncryptedPayloadKeyMissing()
        try testStorageNormalizeStopsWhenOnlyNestedEncryptedPayloadKeyMissing()
        try testStorageTransitionBackupFailureStopsNormalize()
        try testKeychainMigrationSkipsEncryptionService()
        try testPlaintextDataBackup()
        try testFreshAppDefaultsEnableCoreWorkflows()
        try testBrowserCurrentTabParsingAndPermissionMapping()
        try testHotkeyResolverFailsClosed()
        try testPrivateBrowserOpenerPermissionMapping()
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
            throw SmokeTestError.failure("expected U9RL without host to be rejected")
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

    private static func testPinnedBookmarkPersistence() throws {
        let store = BookmarkStore(rootDirectory: try temporaryDirectory())
        let bookmark = try store.add(title: "Pinned", url: "https://pinned.example")

        try store.setPinned(true, ids: [bookmark.id])
        var loaded = try store.bookmarks()
        try expect(loaded.first { $0.id == bookmark.id }?.isPinned == true, "expected pinned state to persist")
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        try expect(!raw.contains("isPinned"), "expected bookmark JSON to omit pinned state")
        var state = BookmarkStateStore(rootDirectory: store.rootDirectory).load()
        try expect(state.pinnedIds == [bookmark.id], "expected pinned id in bookmark_state")

        try store.setPinned(false, ids: [bookmark.id])
        loaded = try store.bookmarks()
        try expect(loaded.first { $0.id == bookmark.id }?.isPinned == false, "expected unpin to clear runtime state")
        state = BookmarkStateStore(rootDirectory: store.rootDirectory).load()
        try expect(state.pinnedIds.isEmpty, "expected unpin to clear pinned state")
    }

    private static func testPinnedClearedByHiddenAndArchive() throws {
        let store = BookmarkStore(rootDirectory: try temporaryDirectory())
        var hiddenCandidate = try store.add(title: "Hide Pinned", url: "https://hide-pinned.example")
        let archiveCandidate = try store.add(title: "Archive Pinned", url: "https://archive-pinned.example")

        try store.setPinned(true, ids: [hiddenCandidate.id, archiveCandidate.id])
        hiddenCandidate.isHidden = true
        _ = try store.update(hiddenCandidate)
        try store.setArchived(true, ids: [archiveCandidate.id])

        let loaded = try store.bookmarks()
        try expect(loaded.first { $0.id == hiddenCandidate.id }?.isPinned == false, "expected hidden bookmark to clear pinned state")
        try expect(loaded.first { $0.id == archiveCandidate.id }?.isPinned == false, "expected archived bookmark to clear pinned state")
        let state = BookmarkStateStore(rootDirectory: store.rootDirectory).load()
        try expect(!state.pinnedIds.contains(hiddenCandidate.id), "expected hidden bookmark to leave pinned state")
        try expect(!state.pinnedIds.contains(archiveCandidate.id), "expected archive bookmark to leave pinned state")
    }

    private static func testStateCleanupOnDelete() throws {
        let root = try temporaryDirectory()
        let store = BookmarkStore(rootDirectory: root)
        let bookmark = try store.add(title: "Delete Me", url: "https://delete-me.example")

        try store.setPinned(true, ids: [bookmark.id])
        var hiddenBookmark = bookmark
        hiddenBookmark.isHidden = true
        _ = try store.update(hiddenBookmark)
        try store.setArchived(true, ids: [bookmark.id])
        _ = try store.applyTitleOptimizations([bookmark.id: "Deleted"])
        var state = BookmarkStateStore(rootDirectory: root).load()
        try expect(state.hiddenIds.contains(bookmark.id), "expected hidden state before delete")
        try expect(state.manualArchivedIds.contains(bookmark.id), "expected archive state before delete")
        try expect(state.pinnedIds.isEmpty, "expected archive to clear pinned state before delete")
        try expect(state.titleOptimizedIds.contains(bookmark.id), "expected title state before delete")
        try expect(state.createdAtById[bookmark.id] != nil, "expected createdAt state before delete")

        try store.delete(id: bookmark.id)
        state = BookmarkStateStore(rootDirectory: root).load()
        try expect(!state.hiddenIds.contains(bookmark.id), "expected delete to clean hidden state")
        try expect(!state.manualArchivedIds.contains(bookmark.id), "expected delete to clean archive state")
        try expect(!state.pinnedIds.contains(bookmark.id), "expected delete to clean pinned state")
        try expect(!state.titleOptimizedIds.contains(bookmark.id), "expected delete to clean title optimization state")
        try expect(state.createdAtById[bookmark.id] == nil, "expected delete to clean createdAt state")
    }

    private static func testEmptyBookmarkLoadDoesNotEraseExistingState() throws {
        let root = try temporaryDirectory()
        let id = try expectUUID("00000000-0000-0000-0000-000000000202")
        let bookmarkURL = ObeliskPrivateStorage.legacyFileURL(rootDirectory: root, logicalName: "bookmarks.json")
        try FileManager.default.createDirectory(
            at: bookmarkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {
          "version": 1,
          "bookmarks": []
        }
        """.write(to: bookmarkURL, atomically: true, encoding: .utf8)

        try BookmarkStateStore(rootDirectory: root).save(
            BookmarkStateDatabase(
                hiddenIds: [id],
                manualArchivedIds: [],
                pinnedIds: [id],
                createdAtById: [id: Date(timeIntervalSince1970: 100)],
                titleOptimizedIds: [id]
            )
        )

        let loaded = try BookmarkStore(rootDirectory: root).bookmarks()
        let state = BookmarkStateStore(rootDirectory: root).load()
        try expect(loaded.isEmpty, "expected empty bookmark file to load as empty")
        try expect(state.hiddenIds == [id], "expected empty bookmark load not to erase hidden state")
        try expect(state.pinnedIds == [id], "expected empty bookmark load not to erase pinned state")
        try expect(state.createdAtById[id] == Date(timeIntervalSince1970: 100), "expected empty bookmark load not to erase createdAt state")
        try expect(state.titleOptimizedIds == [id], "expected empty bookmark load not to erase title state")
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

    private static func testStorageNormalizeKeepsBookmarksWhenNewerEmptyDuplicateExists() throws {
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
              "id": "00000000-0000-0000-0000-000000000306",
              "title": "Real Bookmark",
              "url": "https://real-bookmark.example"
            }
          ]
        }
        """.write(to: legacyURL, atomically: true, encoding: .utf8)
        try SecureJSONFileCodec().writeData(
            Data("""
            {
              "version": 1,
              "bookmarks": []
            }
            """.utf8),
            to: privateURL,
            encrypted: true
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: legacyURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: privateURL.path
        )

        try ObeliskStorageMigrator.normalizeJSONFiles(in: root, encrypted: true, logicalNames: ["bookmarks.json"])

        LocalJSONEncryption.isEnabled = true
        try expect(
            try BookmarkStore(rootDirectory: root).bookmarks().map(\.url) == ["https://real-bookmark.example"],
            "expected non-empty bookmarks to survive newer empty duplicate during normalization"
        )
    }

    private static func testStorageNormalizeAllowsIntentionalEmptyBookmarkDatabase() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        let legacyURL = ObeliskPrivateStorage.legacyFileURL(rootDirectory: root, logicalName: "bookmarks.json")
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {
          "version": 1,
          "bookmarks": []
        }
        """.write(to: legacyURL, atomically: true, encoding: .utf8)

        try ObeliskStorageMigrator.normalizeJSONFiles(in: root, encrypted: true, logicalNames: ["bookmarks.json"])

        LocalJSONEncryption.isEnabled = true
        try expect(try BookmarkStore(rootDirectory: root).bookmarks().isEmpty, "expected intentional empty database to stay valid")
        try expect(
            FileManager.default.fileExists(atPath: ObeliskPrivateStorage.privateFileURL(rootDirectory: root, logicalName: "bookmarks.json").path),
            "expected empty database to migrate to encrypted storage"
        )
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

    private static func testStorageNormalizeMigratesLegacyPrivateDataBackup() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        let bookmark = Bookmark(
            id: try expectUUID("00000000-0000-0000-0000-000000000307"),
            title: "Legacy Private",
            url: "https://legacy-private.example",
            createdAt: Date(timeIntervalSince1970: 300),
            titleOptimized: true,
            isHidden: true
        )
        let state = BookmarkStateDatabase(
            hiddenIds: [bookmark.id],
            manualArchivedIds: [],
            createdAtById: [bookmark.id: bookmark.createdAt],
            titleOptimizedIds: [bookmark.id]
        )
        let usage = [
            bookmark.id.uuidString: UsageRecord(count: 5, lastClickedAt: Date(timeIntervalSince1970: 400))
        ]

        try writeLegacyPrivateJSON(BookmarkDatabase(bookmarks: [bookmark]), logicalName: "bookmarks.json", root: root)
        try writeLegacyPrivateJSON(state, logicalName: "bookmark_state.json", root: root)
        try writeLegacyPrivateJSON(usage, logicalName: "usage.json", root: root)

        try ObeliskStorageMigrator.normalizeJSONFiles(in: root, encrypted: false, logicalNames: ["bookmarks.json", "bookmark_state.json", "usage.json"])

        LocalJSONEncryption.isEnabled = false
        let loaded = try BookmarkStore(rootDirectory: root).bookmarks()
        let loadedState = BookmarkStateStore(rootDirectory: root).load()
        let loadedUsage = UsageStore(rootDirectory: root).load()
        try expect(loaded.map(\.id) == [bookmark.id], "expected legacy PrivateData bookmark backup to migrate")
        try expect(loaded.first?.isHidden == true, "expected migrated legacy PrivateData state to hydrate hidden bookmark")
        try expect(loadedState.createdAtById[bookmark.id] == bookmark.createdAt, "expected migrated legacy PrivateData createdAt state")
        try expect(loadedUsage[bookmark.id]?.count == 5, "expected migrated legacy PrivateData usage")
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

    private static func testStorageNormalizeDecryptsMixedFaviconState() throws {
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

    private static func testStorageNormalizeEncryptsMixedFaviconState() throws {
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
        try expect(
            loaded.first { $0.id == first.id }?.originalTitle == "(14) Inbox | user@example.com | Proton Mail",
            "expected original title to be preserved before optimization"
        )

        let secondPass = try store.applyTitleOptimizations([
            first.id: "Mail",
            second.id: "Claude AI"
        ])
        try expect(secondPass == 0, "expected optimized titles to be skipped on second pass")
        let reloaded = try store.bookmarks()
        try expect(reloaded.first { $0.id == first.id }?.title == "Proton Mail", "expected second pass to preserve optimized title")

        let reverted = try store.revertTitleOptimizations(ids: [first.id])
        try expect(reverted == 1, "expected revert to restore original title")
        let afterRevert = try store.bookmarks()
        try expect(afterRevert.first { $0.id == first.id }?.title == "(14) Inbox | user@example.com | Proton Mail", "expected display title to revert")
        try expect(afterRevert.first { $0.id == first.id }?.titleOptimized == false, "expected optimized flag to clear after revert")

        let forced = try store.applyOriginalTitles([first.id: "Inbox - Proton Mail"], forceApplyDisplay: true)
        try expect(forced == 1, "expected force apply to update optimized bookmark display title")
        let afterForce = try store.bookmarks()
        try expect(afterForce.first { $0.id == first.id }?.title == "Inbox - Proton Mail", "expected forced title on display")
        try expect(afterForce.first { $0.id == first.id }?.titleOptimized == false, "expected force apply to clear optimized flag")
    }

    private static func testTitleOptimizationPreferences() throws {
        let suiteName = "ObeliskTitleOptimizationPreferences-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SmokeTestError.failure("expected test defaults suite")
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let visible = Bookmark(title: "Visible", url: "https://visible.example")
        let hidden = Bookmark(title: "Hidden", url: "https://hidden.example", isHidden: true)
        TitleOptimizationPreferences.register(in: defaults)

        try expect(!TitleOptimizationPreferences.optimizeHiddenBookmarks(in: defaults), "expected hidden title optimization to default off")
        try expect(TitleOptimizationPreferences.allowsOptimization(for: visible, defaults: defaults), "expected visible bookmarks to be optimizable")
        try expect(!TitleOptimizationPreferences.allowsOptimization(for: hidden, defaults: defaults), "expected hidden bookmarks to be blocked by default")
        try expect(!TitleOptimizationPreferences.allowsAutoOptimization(for: visible, defaults: defaults), "expected auto optimization to remain off by default")

        defaults.set(true, forKey: TitleOptimizationPreferences.autoOptimizeNewBookmarksKey)
        try expect(TitleOptimizationPreferences.allowsAutoOptimization(for: visible, defaults: defaults), "expected auto optimization to allow visible bookmarks")
        try expect(!TitleOptimizationPreferences.allowsAutoOptimization(for: hidden, defaults: defaults), "expected auto optimization to block hidden bookmarks while hidden optimization is off")

        defaults.set(true, forKey: TitleOptimizationPreferences.optimizeHiddenBookmarksKey)
        try expect(TitleOptimizationPreferences.allowsOptimization(for: hidden, defaults: defaults), "expected hidden optimization toggle to allow hidden bookmarks")
        try expect(TitleOptimizationPreferences.allowsAutoOptimization(for: hidden, defaults: defaults), "expected auto optimization to allow hidden bookmarks once both toggles are on")
    }

    @MainActor
    private static func testBookmarksModelFiltersHiddenTitleOptimization() async throws {
        let defaults = UserDefaults.standard
        let restoredDefaults = capturedDefaults(
            keys: [
                BookmarksModel.aiFeaturesEnabledKey,
                TitleOptimizationPreferences.optimizeHiddenBookmarksKey
            ],
            defaults: defaults
        )
        defer {
            restoreDefaults(restoredDefaults, defaults: defaults)
        }

        defaults.set(true, forKey: BookmarksModel.aiFeaturesEnabledKey)
        defaults.set(false, forKey: TitleOptimizationPreferences.optimizeHiddenBookmarksKey)

        let root = try temporaryDirectory()
        let store = BookmarkStore(rootDirectory: root)
        let visible = try store.add(title: "Visible Raw", url: "https://visible-filter.example")
        let hidden = try store.add(title: "Hidden Raw", url: "https://hidden-filter.example", isHidden: true)

        let firstOptimizer = StubTitleOptimizer(response: [
            visible.id: "Visible Optimized",
            hidden.id: "Hidden Optimized"
        ])
        let firstModel = BookmarksModel(
            store: store,
            usageStore: UsageStore(rootDirectory: root),
            titleOptimizer: firstOptimizer
        )
        let firstMessage = await firstModel.optimizeTitles(bookmarkIds: [visible.id, hidden.id])
        try expect(firstMessage == "已优化 1 个标题", "expected only visible bookmark to be optimized")
        try expect(firstOptimizer.candidateIDs == [visible.id], "expected hidden bookmark to be filtered before optimizer call")

        defaults.set(true, forKey: TitleOptimizationPreferences.optimizeHiddenBookmarksKey)

        let secondOptimizer = StubTitleOptimizer(response: [
            hidden.id: "Hidden Optimized"
        ])
        let secondModel = BookmarksModel(
            store: store,
            usageStore: UsageStore(rootDirectory: root),
            titleOptimizer: secondOptimizer
        )
        let secondMessage = await secondModel.optimizeTitles(bookmarkIds: [hidden.id])
        try expect(secondMessage == "已优化 1 个标题", "expected hidden bookmark to optimize after enabling hidden optimization")
        try expect(secondOptimizer.candidateIDs == [hidden.id], "expected enabled hidden bookmark to reach optimizer")
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
        let staleLowScore = Bookmark(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            title: "Stale",
            url: "https://stale.example",
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let noUsageAlpha = Bookmark(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            title: "Alpha",
            url: "https://alpha.example",
            createdAt: Date(timeIntervalSince1970: 40)
        )
        let noUsageBeta = Bookmark(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            title: "Beta",
            url: "https://beta.example",
            createdAt: Date(timeIntervalSince1970: 50)
        )
        let legacy = Bookmark(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
            title: "Legacy",
            url: "https://legacy.example",
            createdAt: .distantPast
        )

        let now = Date(timeIntervalSince1970: 1_000_000)
        usageStore.saveAll([
            frequent.id: UsageRecord(count: 5, lastClickedAt: now),
            lowCount.id: UsageRecord(count: 1, lastClickedAt: now),
            staleLowScore.id: UsageRecord(count: 2, lastClickedAt: now.addingTimeInterval(-60 * 86_400))
        ])

        let bookmarks = [frequent, lowCount, legacy]
        try expect(
            usageStore.topFrequent(among: bookmarks + [staleLowScore], limit: 5, now: now).map(\.id) == [frequent.id],
            "expected only count >= 3 bookmark in frequent group"
        )
        try expect(
            usageStore.recent(among: bookmarks, limit: 5).map(\.id) == [lowCount.id, frequent.id],
            "expected recent group to skip legacy dates"
        )
        try expect(
            UsageStore.frecencySorted(
                among: [noUsageBeta, staleLowScore, frequent, lowCount, legacy, noUsageAlpha],
                usage: usageStore.load(),
                now: now
            ).map(\.id) == [
                frequent.id,
                lowCount.id,
                staleLowScore.id,
                noUsageAlpha.id,
                noUsageBeta.id,
                legacy.id
            ],
            "expected full frecency sort with name fallback for unused bookmarks"
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
        let pinnedBookmark = try store.add(title: "Pinned Private", url: "https://pinned-private.example")
        try store.setArchived(true, ids: [bookmark.id])
        try store.setPinned(true, ids: [pinnedBookmark.id])
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
        try expect(!rawText.contains(pinnedBookmark.id.uuidString), "expected encrypted state to hide pinned bookmark id")
        try expect(!rawText.contains("state-private.example"), "expected encrypted state to hide bookmark URL")
        try expect(!rawText.contains("pinned-private.example"), "expected encrypted state to hide pinned bookmark URL")
        try expect(!rawText.contains("State Private"), "expected encrypted state to hide bookmark title")
        try expect(!rawText.contains("Pinned Private"), "expected encrypted state to hide pinned bookmark title")

        let state = stateStore.load()
        try expect(state.hiddenIds == [bookmark.id], "expected encrypted state to read hidden id")
        try expect(state.manualArchivedIds == [bookmark.id], "expected encrypted state to read archive id")
        try expect(state.pinnedIds == [pinnedBookmark.id], "expected encrypted state to read pinned id")
        try expect(state.titleOptimizedIds == [bookmark.id], "expected encrypted state to read title optimized id")
        try expect(state.createdAtById[bookmark.id] != nil, "expected encrypted state to read createdAt")
        try expect(state.createdAtById[pinnedBookmark.id] != nil, "expected encrypted state to read pinned createdAt")
    }

    private static func testEncryptionNormalizationPreservesBookmarksStateAndUsage() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        LocalJSONEncryption.isEnabled = false
        let store = BookmarkStore(rootDirectory: root)
        let visible = try store.add(title: "Visible Toggle", url: "https://visible-toggle.example")
        let hidden = try store.add(title: "Hidden Toggle", url: "https://hidden-toggle.example", isHidden: true)
        try store.setPinned(true, ids: [visible.id])
        _ = try store.applyTitleOptimizations([
            visible.id: "Visible",
            hidden.id: "Hidden"
        ])
        let usageStore = UsageStore(rootDirectory: root)
        usageStore.record(id: visible.id)
        usageStore.record(id: visible.id)

        for encrypted in [true, false, true] {
            try ObeliskStorageMigrator.normalizeStorage(in: root, encrypted: encrypted)
            LocalJSONEncryption.isEnabled = encrypted
            let bookmarks = try BookmarkStore(rootDirectory: root).bookmarks()
            let state = BookmarkStateStore(rootDirectory: root).load()
            let usage = UsageStore(rootDirectory: root).load()

            try expect(bookmarks.count == 2, "expected encryption normalization to preserve bookmark count")
            try expect(bookmarks.first { $0.id == visible.id }?.isPinned == true, "expected encryption normalization to preserve pinned state")
            try expect(bookmarks.first { $0.id == hidden.id }?.isHidden == true, "expected encryption normalization to preserve hidden state")
            try expect(state.createdAtById.count == 2, "expected encryption normalization to preserve createdAt state")
            try expect(state.pinnedIds == [visible.id], "expected encryption normalization to preserve pinned id")
            try expect(state.titleOptimizedIds == [visible.id, hidden.id], "expected encryption normalization to preserve title state")
            try expect(usage[visible.id]?.count == 2, "expected encryption normalization to preserve usage count")
        }
    }

    private static func testBookmarkGroupsEncryptionRoundTrip() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        LocalJSONEncryption.isEnabled = false
        let groupStore = BookmarkGroupStore(rootDirectory: root)
        let bookmarkID = UUID()
        var workID: UUID?

        try groupStore.update { database in
            let work = BookmarkCollection(name: "工作", sortOrder: 0)
            workID = work.id
            database.collections = [work]
            database.membershipByBookmarkId[bookmarkID] = work.id
        }

        for encrypted in [true, false, true] {
            try ObeliskStorageMigrator.normalizeStorage(in: root, encrypted: encrypted)
            LocalJSONEncryption.isEnabled = encrypted
            groupStore.invalidateCache()

            let loaded = groupStore.load()
            try expect(loaded.collections.count == 1, "expected encryption toggle to preserve collection count")
            try expect(loaded.collections.first?.name == "工作", "expected encryption toggle to preserve collection name")
            try expect(loaded.membershipByBookmarkId[bookmarkID] == workID, "expected encryption toggle to preserve membership")

            let groupsURL = groupStore.fileURL
            if encrypted {
                try expect(groupsURL.path.contains("EncryptedData"), "expected encrypted groups under EncryptedData")
                try expect(groupsURL.pathExtension == "bin", "expected encrypted groups to use obscured bin file")
                let raw = try Data(contentsOf: groupsURL)
                let rawText = String(decoding: raw, as: UTF8.self)
                try expect(rawText.contains("obelisk.encrypted-json.v1"), "expected encrypted groups envelope marker")
                try expect(!rawText.contains("工作"), "expected encrypted groups to hide collection name")
            } else {
                try expect(
                    groupsURL.path.contains("Data"),
                    "expected plaintext groups under Data"
                )
            }
        }
    }

    private static func testEncryptionKeyMissingWhenEncryptedPayloadsExist() throws {
        let root = try temporaryDirectory()
        let service = try isolatedEncryptionKeychainService()
        defer { deleteKeychainItems(service: service) }

        let keyStore = KeychainEncryptionKeyStore(encryptedPayloadsRoot: root, keychainService: service)
        let codec = SecureJSONFileCodec(keyStore: keyStore)
        let encryptedURL = ObeliskPrivateStorage.privateFileURL(rootDirectory: root, logicalName: "probe.json")
        try FileManager.default.createDirectory(
            at: encryptedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try codec.writeData(Data("{\"sealed\":true}".utf8), to: encryptedURL, encrypted: true)
        deleteKeychainItems(service: service)

        do {
            _ = try keyStore.getOrCreateKey()
            throw SmokeTestError.failure("expected getOrCreateKey to fail when encrypted payloads exist without a key")
        } catch let error as SecureJSONFileCodecError {
            guard case .encryptionKeyMissing = error else { throw error }
        }
    }

    private static func testEncryptionKeyRefusesOverwrite() throws {
        let root = try temporaryDirectory()
        let service = try isolatedEncryptionKeychainService()
        defer { deleteKeychainItems(service: service) }

        let keyStore = KeychainEncryptionKeyStore(encryptedPayloadsRoot: root, keychainService: service)
        let codec = SecureJSONFileCodec(keyStore: keyStore)
        let encryptedURL = ObeliskPrivateStorage.privateFileURL(rootDirectory: root, logicalName: "probe.json")
        try FileManager.default.createDirectory(
            at: encryptedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try codec.writeData(Data("{\"protected\":true}".utf8), to: encryptedURL, encrypted: true)

        let originalData = try keyStore.getExistingKey().withUnsafeBytes { Data($0) }
        let wrongData = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }

        do {
            try keyStore.persistEncryptionKeyMaterial(wrongData)
            throw SmokeTestError.failure("expected persistEncryptionKeyMaterial to refuse overwriting encryption key")
        } catch let error as SecureJSONFileCodecError {
            guard case .encryptionKeyWouldOverwrite = error else { throw error }
        }

        let restoredData = try keyStore.getExistingKey().withUnsafeBytes { Data($0) }
        try expect(restoredData == originalData, "expected encryption key to remain unchanged after refused overwrite")
        let roundTrip = try codec.readData(from: encryptedURL)
        try expect(String(decoding: roundTrip, as: UTF8.self).contains("protected"), "expected encrypted payload to remain readable")
    }

    private static func testStorageNormalizeStopsWhenEncryptedPayloadKeyMissing() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        let service = try isolatedEncryptionKeychainService()
        defer { deleteKeychainItems(service: service) }

        LocalJSONEncryption.isEnabled = false
        let plaintextURL = ObeliskPrivateStorage.legacyFileURL(rootDirectory: root, logicalName: "bookmarks.json")
        try FileManager.default.createDirectory(
            at: plaintextURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {
          "version": 1,
          "bookmarks": []
        }
        """.write(to: plaintextURL, atomically: true, encoding: .utf8)

        let keyStore = KeychainEncryptionKeyStore(encryptedPayloadsRoot: root, keychainService: service)
        let codec = SecureJSONFileCodec(keyStore: keyStore)
        let encryptedURL = ObeliskPrivateStorage.privateFileURL(rootDirectory: root, logicalName: "bookmarks.json")
        try codec.writeData(
            Data("""
            {
              "version": 1,
              "bookmarks": [
                {
                  "id": "00000000-0000-0000-0000-000000000909",
                  "title": "Encrypted",
                  "url": "https://encrypted.example"
                }
              ]
            }
            """.utf8),
            to: encryptedURL,
            encrypted: true
        )
        deleteKeychainItems(service: service)

        do {
            try ObeliskStorageMigrator.normalizeStorage(in: root, encrypted: false, keyStore: keyStore)
            throw SmokeTestError.failure("expected normalizeStorage to stop before migrating unreadable encrypted data")
        } catch let error as SecureJSONFileCodecError {
            guard case .encryptionKeyMissing = error else { throw error }
        }

        try expect(FileManager.default.fileExists(atPath: plaintextURL.path), "expected plaintext file to remain")
        try expect(FileManager.default.fileExists(atPath: encryptedURL.path), "expected unreadable encrypted file to remain")
    }

    private static func testStorageNormalizeStopsWhenOnlyNestedEncryptedPayloadKeyMissing() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        let service = try isolatedEncryptionKeychainService()
        defer { deleteKeychainItems(service: service) }

        LocalJSONEncryption.isEnabled = false
        let keyStore = KeychainEncryptionKeyStore(encryptedPayloadsRoot: root, keychainService: service)
        let codec = SecureJSONFileCodec(keyStore: keyStore)
        let encryptedIconURL = ObeliskPrivateStorage.faviconIconURL(
            rootDirectory: root,
            key: "nested-only",
            encrypted: true
        )
        try codec.writeData(Data("encrypted favicon".utf8), to: encryptedIconURL, encrypted: true)
        deleteKeychainItems(service: service)

        do {
            try ObeliskStorageMigrator.normalizeStorage(in: root, encrypted: false, keyStore: keyStore)
            throw SmokeTestError.failure("expected normalizeStorage to stop before migrating unreadable nested encrypted data")
        } catch let error as SecureJSONFileCodecError {
            guard case .encryptionKeyMissing = error else { throw error }
        }

        try expect(
            FileManager.default.fileExists(atPath: encryptedIconURL.path),
            "expected unreadable nested encrypted file to remain"
        )
    }

    private static func testStorageTransitionBackupFailureStopsNormalize() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        LocalJSONEncryption.isEnabled = false
        let store = BookmarkStore(rootDirectory: root)
        _ = try store.add(title: "Do Not Migrate", url: "https://do-not-migrate.example")

        let plaintextURL = store.fileURL
        let encryptedURL = ObeliskPrivateStorage.privateFileURL(rootDirectory: root, logicalName: "bookmarks.json")

        do {
            try ObeliskStorageTransition.backUpThenNormalize(
                in: root,
                encrypted: true,
                backup: { _ in
                    throw ObeliskPlaintextDataBackup.BackupError.destinationAlreadyExists(root)
                }
            )
            throw SmokeTestError.failure("expected backup failure to stop storage normalization")
        } catch ObeliskPlaintextDataBackup.BackupError.destinationAlreadyExists {
        }

        try expect(FileManager.default.fileExists(atPath: plaintextURL.path), "expected plaintext file to remain")
        try expect(!FileManager.default.fileExists(atPath: encryptedURL.path), "expected encrypted file not to be created")
    }

    private static func testKeychainMigrationSkipsEncryptionService() throws {
        let root = try temporaryDirectory()
        let service = try isolatedEncryptionKeychainService()
        defer { deleteKeychainItems(service: service) }

        let keyStore = KeychainEncryptionKeyStore(encryptedPayloadsRoot: root, keychainService: service)
        let codec = SecureJSONFileCodec(keyStore: keyStore)
        let encryptedURL = ObeliskPrivateStorage.privateFileURL(rootDirectory: root, logicalName: "probe.json")
        try FileManager.default.createDirectory(
            at: encryptedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try codec.writeData(Data("{\"migration\":true}".utf8), to: encryptedURL, encrypted: true)

        ObeliskKeychainMigration.migrateIfNeeded()

        let roundTrip = try codec.readData(from: encryptedURL)
        try expect(String(decoding: roundTrip, as: UTF8.self).contains("migration"), "expected payload readable after migration")
    }

    private static func isolatedEncryptionKeychainService() throws -> String {
        "com.eli.Obelisk.encryption.smoke.\(UUID().uuidString)"
    }

    private static func deleteKeychainItems(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    private static func testPlaintextDataBackup() throws {
        let root = try temporaryDirectory()
        let store = BookmarkStore(rootDirectory: root)
        _ = try store.add(title: "Backup Me", url: "https://backup-me.example")

        let result = try ObeliskPlaintextDataBackup.createBackup(in: root)
        try expect(result.destinationURL.lastPathComponent.hasPrefix("Backup-"), "expected dated backup folder name")
        let bookmarksURL = result.destinationURL
            .appendingPathComponent("Data")
            .appendingPathComponent("bookmarks.json")
        try expect(FileManager.default.fileExists(atPath: bookmarksURL.path), "expected plaintext bookmarks backup")
        let raw = try String(contentsOf: bookmarksURL, encoding: .utf8)
        try expect(raw.contains("backup-me.example"), "expected backup to contain bookmark URL")
        try expect(!raw.contains("obelisk.encrypted-json.v1"), "expected backup to be plaintext JSON")
    }

    private static func testFreshAppDefaultsEnableCoreWorkflows() throws {
        let oldSuiteName = "local.elidev.Obelisk.test.\(UUID().uuidString)"
        let freshSuiteName = "com.eli.Obelisk.test.\(UUID().uuidString)"
        guard
            let oldDefaults = UserDefaults(suiteName: oldSuiteName),
            let freshDefaults = UserDefaults(suiteName: freshSuiteName)
        else {
            throw SmokeTestError.failure("expected test defaults suites")
        }
        defer {
            oldDefaults.removePersistentDomain(forName: oldSuiteName)
            freshDefaults.removePersistentDomain(forName: freshSuiteName)
        }

        oldDefaults.set(false, forKey: ObeliskAppDefaults.silentAddEnabledKey)
        oldDefaults.set(false, forKey: ObeliskAppDefaults.openHiddenBookmarksIncognitoKey)
        oldDefaults.set("legacy-window-id", forKey: "diaIncognitoWindowID")

        ObeliskAppDefaults.register(in: freshDefaults)

        try expect(
            freshDefaults.bool(forKey: ObeliskAppDefaults.silentAddEnabledKey),
            "expected fresh app defaults to enable silent add"
        )
        try expect(
            freshDefaults.bool(forKey: ObeliskAppDefaults.openHiddenBookmarksIncognitoKey),
            "expected fresh app defaults to enable incognito hidden bookmarks"
        )
        try expect(
            freshDefaults.string(forKey: "diaIncognitoWindowID") == nil,
            "expected fresh app defaults not to import legacy Dia window state"
        )
        try expect(
            freshDefaults.bool(forKey: TitleOptimizationPreferences.optimizeHiddenBookmarksKey) == false,
            "expected fresh app defaults to keep hidden title optimization off"
        )
        try expect(
            oldDefaults.bool(forKey: ObeliskAppDefaults.silentAddEnabledKey) == false,
            "expected legacy defaults suite to stay isolated"
        )
        try expect(
            oldDefaults.bool(forKey: ObeliskAppDefaults.openHiddenBookmarksIncognitoKey) == false,
            "expected legacy incognito preference to stay isolated"
        )
    }

    private static func testBrowserCurrentTabParsingAndPermissionMapping() throws {
        try expect(
            BrowserCurrentTab.parseScriptOutput("https://example.com/path\nExample") == .success(
                BrowserTab(url: "https://example.com/path", title: "Example")
            ),
            "expected valid browser tab output to parse"
        )
        try expect(
            BrowserCurrentTab.parseScriptOutput(BrowserCurrentTab.noWindowSentinel) == .failure(.noBrowserWindow),
            "expected no-window sentinel to stay explicit"
        )
        try expect(
            BrowserCurrentTab.parseScriptOutput("not-a-url\nBad") == .failure(.invalidURL),
            "expected invalid tab URL to fail"
        )
        try expect(
            BrowserCurrentTab.result(forAppleScriptError: [
                "NSAppleScriptErrorNumber": NSNumber(value: -1743)
            ]) == .failure(.automationPermissionRequired),
            "expected Apple Events permission failures to be explicit"
        )
        try expect(
            BrowserCurrentTab.result(forAppleScriptError: [
                "NSAppleScriptErrorNumber": NSNumber(value: -1728)
            ]) == .failure(.scriptFailed(-1728)),
            "expected non-permission AppleScript errors to remain script failures"
        )
    }

    private static func testHotkeyResolverFailsClosed() throws {
        try expect(
            HotkeyBookmarkResolver.resolve(
                currentTab: .success(BrowserTab(url: "https://current.example", title: "Current"))
            ) == .resolved(url: "https://current.example", title: "Current"),
            "expected hotkey resolver to use the confirmed current tab"
        )
        try expect(
            HotkeyBookmarkResolver.resolve(currentTab: .failure(.automationPermissionRequired)) == .failed(
                message: "请在“隐私与安全性 > 自动化”允许 Obelisk 控制当前浏览器",
                settingsDestination: .automation
            ),
            "expected browser permission failures not to resolve a fallback URL"
        )
        try expect(
            HotkeyBookmarkResolver.resolve(currentTab: .failure(.unsupportedFrontmostApplication("com.apple.finder"))) == .failed(
                message: "请先切到要添加的浏览器标签页",
                settingsDestination: nil
            ),
            "expected non-browser frontmost apps not to resolve a fallback URL"
        )
        try expect(
            HotkeyBookmarkResolver.resolve(currentTab: .failure(.invalidURL)) == .failed(
                message: "当前浏览器标签无有效网址",
                settingsDestination: nil
            ),
            "expected invalid current tabs not to resolve a fallback URL"
        )
    }

    private static func testPrivateBrowserOpenerPermissionMapping() throws {
        try expect(
            PrivateBrowserOpener.result(forAppleScriptError: [
                "NSAppleScriptErrorNumber": NSNumber(value: -1743)
            ]) == .automationPermissionRequired(.appleEvents),
            "expected Dia Apple Events failures to request automation permission"
        )
        try expect(
            PrivateBrowserOpener.result(forAppleScriptError: [
                "NSAppleScriptErrorNumber": NSNumber(value: -1728)
            ]) == .openFailed,
            "expected ordinary Dia AppleScript failures to stay open failures"
        )
    }

    private static func testBookmarkCollectionMembership() throws {
        let root = try temporaryDirectory()
        let groupStore = BookmarkGroupStore(rootDirectory: root)
        var workID: UUID?

        try groupStore.update { database in
            let work = BookmarkCollection(name: "工作", sortOrder: 0)
            workID = work.id
            database.collections = [work]
        }

        let bookmarkID = UUID()
        try groupStore.update { database in
            database.membershipByBookmarkId[bookmarkID] = workID
        }

        let loaded = groupStore.load()
        try expect(loaded.collections.count == 1, "expected one collection")
        try expect(loaded.collections.first?.name == "工作", "expected collection name to round-trip")
        try expect(loaded.membershipByBookmarkId[bookmarkID] == workID, "expected membership to round-trip")

        try groupStore.removeMembership(for: [bookmarkID])
        try expect(groupStore.load().membershipByBookmarkId[bookmarkID] == nil, "expected membership removal")
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

    private static func capturedDefaults(
        keys: [String],
        defaults: UserDefaults
    ) -> [String: Any?] {
        Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, defaults.object(forKey: key))
        })
    }

    private static func restoreDefaults(
        _ values: [String: Any?],
        defaults: UserDefaults
    ) {
        for (key, value) in values {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private static func writeLegacyPrivateJSON<T: Encodable>(_ value: T, logicalName: String, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try SecureJSONFileCodec().writeData(
            data,
            to: ObeliskPrivateStorage.legacyPrivateFileURL(rootDirectory: root, logicalName: logicalName),
            encrypted: true
        )
    }

    private static func expectBookmarkJSONContainsOnlyCoreFields(_ raw: String) throws {
        for forbidden in ["archivedAt", "isHidden", "isPinned", "titleOptimized", "createdAt"] {
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

private final class StubTitleOptimizer: TitleOptimizing {
    private let response: [UUID: String]
    private(set) var candidateIDs: [UUID] = []

    init(response: [UUID: String]) {
        self.response = response
    }

    func optimize(_ candidates: [TitleOptimizationCandidate]) async throws -> [UUID: String] {
        candidateIDs = candidates.map(\.id)
        return response
    }
}

@Suite struct ObeliskTests {
    @MainActor
    @Test func smokeSuite() async throws {
        try await SmokeTests.main()
    }
}
