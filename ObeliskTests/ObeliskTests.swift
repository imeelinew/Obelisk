import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Security
import SwiftUI
import Testing
@testable import Obelisk

@Suite(.serialized)
struct SmokeTests {
    /// Every test runs against a throwaway OBELISK_HOME with encryption
    /// disabled, restoring process-global state afterwards. These globals are
    /// why the suite is `.serialized`.
    @MainActor
    private static func withIsolatedEnvironment(_ body: @MainActor () async throws -> Void) async throws {
        let isolatedHome = try temporaryDirectory()
        setenv("OBELISK_HOME", isolatedHome.path, 1)
        LocalJSONEncryption.isEnabled = false
        defer {
            unsetenv("OBELISK_HOME")
            LocalJSONEncryption.isEnabled = false
            try? FileManager.default.removeItem(at: isolatedHome)
        }
        try await body()
    }

    @MainActor @Test func defaultRootDirectoryUsesVault() async throws {
        try await Self.withIsolatedEnvironment { try Self.testDefaultRootDirectoryUsesVault() }
    }
    @MainActor @Test func defaultRootDirectoryUsesApplicationSupport() async throws {
        try await Self.withIsolatedEnvironment { try Self.testDefaultRootDirectoryUsesApplicationSupport() }
    }
    @MainActor @Test func duplicateProtection() async throws {
        try await Self.withIsolatedEnvironment { try Self.testDuplicateProtection() }
    }
    @MainActor @Test func webURLValidation() async throws {
        try await Self.withIsolatedEnvironment { try Self.testWebURLValidation() }
    }
    @MainActor @Test func hiddenBookmarkPersistence() async throws {
        try await Self.withIsolatedEnvironment { try Self.testHiddenBookmarkPersistence() }
    }
    @MainActor @Test func hiddenBookmarkKeywordExclusion() async throws {
        try await Self.withIsolatedEnvironment { try Self.testHiddenBookmarkKeywordExclusion() }
    }
    @MainActor @Test func nativeBookmarkListSelectionKeepsDuplicateRowsSeparate() async throws {
        try await Self.withIsolatedEnvironment { try Self.testNativeBookmarkListSelectionKeepsDuplicateRowsSeparate() }
    }
    @MainActor @Test func nativeBookmarkListFirstBookmarkRowSkipsHeaders() async throws {
        try await Self.withIsolatedEnvironment { try Self.testNativeBookmarkListFirstBookmarkRowSkipsHeaders() }
    }
    @MainActor @Test func menuBarSearchKeyCommandHandlesEscapeAndEnterOnly() async throws {
        try await Self.withIsolatedEnvironment { try Self.testMenuBarSearchKeyCommandHandlesEscapeAndEnterOnly() }
    }
    @MainActor @Test func nativeSearchFieldEnterUsesFieldEditorText() async throws {
        try await Self.withIsolatedEnvironment { try Self.testNativeSearchFieldEnterUsesFieldEditorText() }
    }
    @MainActor @Test func nativeSearchFieldEscapeUsesFirstCommand() async throws {
        try await Self.withIsolatedEnvironment { try Self.testNativeSearchFieldEscapeUsesFirstCommand() }
    }
    @MainActor @Test func menuBarSearchCommandBridgeOpensOnce() async throws {
        try await Self.withIsolatedEnvironment { try Self.testMenuBarSearchCommandBridgeOpensOnce() }
    }
    @MainActor @Test func bookmarkMenuTableViewReturnOpensSelection() async throws {
        try await Self.withIsolatedEnvironment { try Self.testBookmarkMenuTableViewReturnOpensSelection() }
    }
    @MainActor @Test func archivePersistence() async throws {
        try await Self.withIsolatedEnvironment { try Self.testArchivePersistence() }
    }
    @MainActor @Test func manualArchiveIndependentOfAutoArchiveSetting() async throws {
        try await Self.withIsolatedEnvironment { try Self.testManualArchiveIndependentOfAutoArchiveSetting() }
    }
    @MainActor @Test func pinnedBookmarkPersistence() async throws {
        try await Self.withIsolatedEnvironment { try Self.testPinnedBookmarkPersistence() }
    }
    @MainActor @Test func bookmarkSearchMatcherSupportsPinyin() async throws {
        try await Self.withIsolatedEnvironment { try Self.testBookmarkSearchMatcherSupportsPinyin() }
    }
    @MainActor @Test func bookmarkSearchCandidatesExcludeHiddenAndIncludeArchived() async throws {
        try await Self.withIsolatedEnvironment { try Self.testBookmarkSearchCandidatesExcludeHiddenAndIncludeArchived() }
    }
    @MainActor @Test func librarySectionsPrioritizePinnedBookmarks() async throws {
        try await Self.withIsolatedEnvironment { try Self.testLibrarySectionsPrioritizePinnedBookmarks() }
    }
    @MainActor @Test func pinnedClearedByHiddenAndArchive() async throws {
        try await Self.withIsolatedEnvironment { try Self.testPinnedClearedByHiddenAndArchive() }
    }
    @MainActor @Test func stateCleanupOnDelete() async throws {
        try await Self.withIsolatedEnvironment { try Self.testStateCleanupOnDelete() }
    }
    @MainActor @Test func emptyBookmarkLoadCreatesEmptyVaultPayload() async throws {
        try await Self.withIsolatedEnvironment { try Self.testEmptyBookmarkLoadCreatesEmptyVaultPayload() }
    }
    @MainActor @Test func usageStoreCacheInvalidation() async throws {
        try await Self.withIsolatedEnvironment { try Self.testUsageStoreCacheInvalidation() }
    }
    @MainActor @Test func bookmarkStoreCacheInvalidation() async throws {
        try await Self.withIsolatedEnvironment { try Self.testBookmarkStoreCacheInvalidation() }
    }
    @MainActor @Test func vaultDirectoryIsMarkedAsPackage() async throws {
        try await Self.withIsolatedEnvironment { try Self.testVaultDirectoryIsMarkedAsPackage() }
    }
    @MainActor @Test func vaultPayloadUsesVaultRoot() async throws {
        try await Self.withIsolatedEnvironment { try Self.testVaultPayloadUsesVaultRoot() }
    }
    @MainActor @Test func hiddenDuplicateProtection() async throws {
        try await Self.withIsolatedEnvironment { try Self.testHiddenDuplicateProtection() }
    }
    @MainActor @Test func batchDelete() async throws {
        try await Self.withIsolatedEnvironment { try Self.testBatchDelete() }
    }
    @MainActor @Test func titleOptimizationPersistence() async throws {
        try await Self.withIsolatedEnvironment { try Self.testTitleOptimizationPersistence() }
    }
    @MainActor @Test func titleOptimizationPreferences() async throws {
        try await Self.withIsolatedEnvironment { try Self.testTitleOptimizationPreferences() }
    }
    @MainActor @Test func titleOptimizationTranslationPrompt() async throws {
        try await Self.withIsolatedEnvironment { try Self.testTitleOptimizationTranslationPrompt() }
    }
    @MainActor @Test func bookmarksModelFiltersHiddenTitleOptimization() async throws {
        try await Self.withIsolatedEnvironment { try await Self.testBookmarksModelFiltersHiddenTitleOptimization() }
    }
    @MainActor @Test func bookmarksModelTitleOptimizationOutcomeIncludesUpdatedTitle() async throws {
        try await Self.withIsolatedEnvironment { try await Self.testBookmarksModelTitleOptimizationOutcomeIncludesUpdatedTitle() }
    }
    @MainActor @Test func bookmarkIntelligenceAutomaticOptions() async throws {
        try await Self.withIsolatedEnvironment { try Self.testBookmarkIntelligenceAutomaticOptions() }
    }
    @MainActor @Test func bookmarksModelCombinedOptimizationUsesUpdatedTitles() async throws {
        try await Self.withIsolatedEnvironment { try await Self.testBookmarksModelCombinedOptimizationUsesUpdatedTitles() }
    }
    @MainActor @Test func bookmarkIntelligenceOutcomeSummary() async throws {
        try await Self.withIsolatedEnvironment { try Self.testBookmarkIntelligenceOutcomeSummary() }
    }
    @MainActor @Test func bookmarksModelAutoGroupsUngroupedBookmarks() async throws {
        try await Self.withIsolatedEnvironment { try await Self.testBookmarksModelAutoGroupsUngroupedBookmarks() }
    }
    @MainActor @Test func bookmarksModelAutoGroupingSkipsGroupedPinnedAndHiddenBookmarks() async throws {
        try await Self.withIsolatedEnvironment { try await Self.testBookmarksModelAutoGroupingSkipsGroupedPinnedAndHiddenBookmarks() }
    }
    @MainActor @Test func bookmarkAutoGroupingSingleDescription() async throws {
        try await Self.withIsolatedEnvironment { try Self.testBookmarkAutoGroupingSingleDescription() }
    }
    @MainActor @Test func usageGroupingFilters() async throws {
        try await Self.withIsolatedEnvironment { try Self.testUsageGroupingFilters() }
    }
    @MainActor @Test func encryptedBookmarkStoreRoundTrip() async throws {
        try await Self.withIsolatedEnvironment { try Self.testEncryptedBookmarkStoreRoundTrip() }
    }
    @MainActor @Test func encryptedBookmarkStateStoreRoundTrip() async throws {
        try await Self.withIsolatedEnvironment { try Self.testEncryptedBookmarkStateStoreRoundTrip() }
    }
    @MainActor @Test func bookmarkGroupsEncryptionRoundTrip() async throws {
        try await Self.withIsolatedEnvironment { try Self.testBookmarkGroupsEncryptionRoundTrip() }
    }
    @MainActor @Test func bookmarkCollectionMembership() async throws {
        try await Self.withIsolatedEnvironment { try Self.testBookmarkCollectionMembership() }
    }
    @MainActor @Test func encryptionKeyRefusesOverwrite() async throws {
        try await Self.withIsolatedEnvironment { try Self.testEncryptionKeyRefusesOverwrite() }
    }
    @MainActor @Test func encryptionKeyMissingWhenEncryptedPayloadsExist() async throws {
        try await Self.withIsolatedEnvironment { try Self.testEncryptionKeyMissingWhenEncryptedPayloadsExist() }
    }
    @MainActor @Test func plaintextDataBackup() async throws {
        try await Self.withIsolatedEnvironment { try Self.testPlaintextDataBackup() }
    }
    @MainActor @Test func freshAppDefaultsEnableCoreWorkflows() async throws {
        try await Self.withIsolatedEnvironment { try Self.testFreshAppDefaultsEnableCoreWorkflows() }
    }
    @MainActor @Test func intelligenceIconContract() async throws {
        try await Self.withIsolatedEnvironment { try Self.testIntelligenceIconContract() }
    }
    @MainActor @Test func localJSONEncryptionDefaultsForceProductionEncryption() async throws {
        try await Self.withIsolatedEnvironment { try Self.testLocalJSONEncryptionDefaultsForceProductionEncryption() }
    }
    @MainActor @Test func browserCurrentTabParsingAndPermissionMapping() async throws {
        try await Self.withIsolatedEnvironment { try Self.testBrowserCurrentTabParsingAndPermissionMapping() }
    }
    @MainActor @Test func hotkeyResolverFailsClosed() async throws {
        try await Self.withIsolatedEnvironment { try Self.testHotkeyResolverFailsClosed() }
    }
    @MainActor @Test func privateBrowserOpenerPermissionMapping() async throws {
        try await Self.withIsolatedEnvironment { try Self.testPrivateBrowserOpenerPermissionMapping() }
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

    private static func testDefaultRootDirectoryUsesVault() throws {
        let previousOverride = ProcessInfo.processInfo.environment["OBELISK_HOME"]
        unsetenv("OBELISK_HOME")
        defer {
            if let previousOverride {
                setenv("OBELISK_HOME", previousOverride, 1)
            } else {
                unsetenv("OBELISK_HOME")
            }
        }

        let expected = BookmarkStore.applicationSupportRootDirectory()
        try expect(BookmarkStore.defaultRootDirectory() == expected, "expected default storage root to use Obelisk.obelisk")
        try expect(expected.lastPathComponent == ObeliskPrivateStorage.vaultDirectoryName, "expected default storage root to remain an Obelisk vault")
    }

    private static func testDefaultRootDirectoryUsesApplicationSupport() throws {
        let previousOverride = ProcessInfo.processInfo.environment["OBELISK_HOME"]
        unsetenv("OBELISK_HOME")
        defer {
            if let previousOverride {
                setenv("OBELISK_HOME", previousOverride, 1)
            } else {
                unsetenv("OBELISK_HOME")
            }
        }

        let root = BookmarkStore.defaultRootDirectory()
        try expect(root.path.contains("/Library/Application Support/"), "expected default storage root to live in Application Support")
        try expect(root.deletingLastPathComponent().lastPathComponent == "com.eli.Obelisk", "expected default storage root to use the app bundle identifier folder")
    }

    private static func testIntelligenceIconContract() throws {
        try expect(
            IntelligenceSymbolIcon.symbolName == "siri",
            "expected the shared Intelligence icon to use the Siri symbol"
        )
        try expect(
            BookmarkManagerView.SettingsPage.ai.symbolName == IntelligenceSymbolIcon.symbolName,
            "expected the sidebar Intelligence icon to use the shared symbol"
        )
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

    private static func testHiddenBookmarkPersistence() throws {
        let store = BookmarkStore(rootDirectory: try temporaryDirectory())
        let hidden = try store.add(title: "Hidden", url: "https://hidden.example", isHidden: true)
        let visible = try store.add(title: "Visible", url: "https://visible.example")

        let loaded = try store.bookmarks()
        try expect(loaded.first { $0.id == hidden.id }?.isHidden == true, "expected hidden bookmark flag to persist")
        try expect(loaded.first { $0.id == visible.id }?.isHidden == false, "expected visible bookmark flag to default false")
    }

    @MainActor
    private static func testHiddenBookmarkKeywordExclusion() throws {
        let standardDefaults = UserDefaults.standard
        let restoredDefaults = capturedDefaults(
            keys: [
                HiddenBookmarkKeywordExclusion.storageKey
            ],
            defaults: standardDefaults
        )
        defer {
            restoreDefaults(restoredDefaults, defaults: standardDefaults)
        }

        let suiteName = "ObeliskHiddenBookmarkKeywordExclusion-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SmokeTestError.failure("expected test defaults suite")
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("private\nPRIVATE\n  token  \n\n", forKey: HiddenBookmarkKeywordExclusion.storageKey)
        try expect(
            HiddenBookmarkKeywordExclusion.keywords(in: defaults) == ["private", "token"],
            "expected keyword parsing to trim and deduplicate"
        )
        try expect(
            HiddenBookmarkKeywordExclusion.matches(url: "https://example.com/path?access_token=1", defaults: defaults),
            "expected keyword match inside URL"
        )

        standardDefaults.set("private", forKey: HiddenBookmarkKeywordExclusion.storageKey)
        let root = try temporaryDirectory()
        let model = BookmarksModel(store: BookmarkStore(rootDirectory: root), usageStore: UsageStore(rootDirectory: root))
        let blockedResult = model.addBookmark(title: "Private", url: "https://example.com/private/page", isHidden: false)
        guard case .failure(let blockedError) = blockedResult else {
            throw SmokeTestError.failure("expected keyword-matched ordinary add to fail")
        }
        try expect(
            blockedError.localizedDescription == HiddenBookmarkKeywordExclusion.blockedBookmarkMessage,
            "expected keyword-matched ordinary add to use generic failure message"
        )

        let hiddenResult = model.addBookmark(title: "Private", url: "https://example.com/private/page", isHidden: true)
        guard case .success(let hiddenBookmark) = hiddenResult else {
            throw SmokeTestError.failure("expected keyword-matched hidden add to succeed")
        }
        try expect(hiddenBookmark.isHidden, "expected keyword-matched hidden add to stay hidden")
        try expect(
            model.setHidden(false, for: hiddenBookmark.id) == HiddenBookmarkKeywordExclusion.blockedBookmarkMessage,
            "expected keyword-matched hidden bookmark not to move back to ordinary bookmarks"
        )

        let visibleResult = model.addBookmark(title: "Visible", url: "https://example.com/public", isHidden: false)
        guard case .success(let visibleBookmark) = visibleResult else {
            throw SmokeTestError.failure("expected non-matching bookmark add to succeed")
        }
        try expect(!visibleBookmark.isHidden, "expected non-matching ordinary add to stay visible")

        var updatedVisibleBookmark = visibleBookmark
        updatedVisibleBookmark.url = "https://example.com/private/updated"
        try expect(
            model.update(updatedVisibleBookmark) == HiddenBookmarkKeywordExclusion.blockedBookmarkMessage,
            "expected keyword-matched visible update to fail"
        )
    }

    private static func testNativeBookmarkListSelectionKeepsDuplicateRowsSeparate() throws {
        let bookmark = Bookmark(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            title: "Duplicate",
            url: "https://duplicate.example"
        )
        let items = [
            BookmarkListSection(
                title: "最近添加 (1)",
                bookmarks: [bookmark],
                referenceIndicatorSystemImage: FaviconReferenceBadge.systemImageName
            ),
            BookmarkListSection(
                title: "未分组 (1)",
                bookmarks: [bookmark]
            )
        ].flattenedItems

        try expect(items.count == 4, "expected two headers and two bookmark rows")
        try expect(items[1].isReference, "expected recent bookmark row to be marked as reference")
        try expect(!items[3].isReference, "expected ungrouped bookmark row to be marked as primary")

        let recentSelection = NativeBookmarkSelectionResolver.selection(
            from: IndexSet(integer: 1),
            in: items,
            allowsCollectionSelection: false
        )
        try expect(
            recentSelection.bookmarkIDs == Set([bookmark.id]),
            "expected recent row selection to keep bookmark action id"
        )
        try expect(
            NativeBookmarkSelectionResolver.rowIndexes(
                for: recentSelection.bookmarkIDs,
                selectedRowKeys: recentSelection.rowKeys,
                selectedCollectionId: nil,
                in: items
            ) == IndexSet(integer: 1),
            "expected recent row selection to sync only the recent row"
        )

        let ungroupedSelection = NativeBookmarkSelectionResolver.selection(
            from: IndexSet(integer: 3),
            in: items,
            allowsCollectionSelection: false
        )
        try expect(
            NativeBookmarkSelectionResolver.rowIndexes(
                for: ungroupedSelection.bookmarkIDs,
                selectedRowKeys: ungroupedSelection.rowKeys,
                selectedCollectionId: nil,
                in: items
            ) == IndexSet(integer: 3),
            "expected ungrouped row selection to sync only the ungrouped row"
        )

        try expect(
            NativeBookmarkSelectionResolver.rowIndexes(
                for: Set([bookmark.id]),
                selectedRowKeys: [],
                selectedCollectionId: nil,
                in: items
            ) == IndexSet(integer: 3),
            "expected bookmark-id fallback to prefer the non-reference row"
        )
    }

    private static func testArchivePersistence() throws {
        let store = BookmarkStore(rootDirectory: try temporaryDirectory())
        let bookmark = try store.add(title: "Archive", url: "https://archive.example")
        let archivedAt = Date(timeIntervalSince1970: 123)

        try store.setArchived(true, ids: [bookmark.id], at: archivedAt)
        var loaded = try store.bookmarks()
        try expect(loaded.first { $0.id == bookmark.id }?.archivedAt != nil, "expected manual archive state to persist")
        let payload = try loadVaultPayload(root: store.rootDirectory)
        try expect(payload.bookmarks.first { $0.id == bookmark.id }?.archivedAt == archivedAt, "expected payload to include archivedAt state")
        var state = BookmarkStateStore(rootDirectory: store.rootDirectory).load()
        try expect(state.manualArchivedIds == [bookmark.id], "expected manual archive id in bookmark_state")

        try store.setArchived(false, ids: [bookmark.id])
        loaded = try store.bookmarks()
        try expect(loaded.first { $0.id == bookmark.id }?.archivedAt == nil, "expected archive restore to clear archivedAt")
        state = BookmarkStateStore(rootDirectory: store.rootDirectory).load()
        try expect(state.manualArchivedIds.isEmpty, "expected restore to clear manual archive id")
    }

    @MainActor
    private static func testManualArchiveIndependentOfAutoArchiveSetting() throws {
        let defaults = UserDefaults.standard
        let restoredDefaults = capturedDefaults(
            keys: [BookmarksModel.autoArchiveEnabledKey],
            defaults: defaults
        )
        defer {
            restoreDefaults(restoredDefaults, defaults: defaults)
        }

        defaults.set(false, forKey: BookmarksModel.autoArchiveEnabledKey)
        let root = try temporaryDirectory()
        let store = BookmarkStore(rootDirectory: root)
        let bookmark = try store.add(title: "Manual Archive", url: "https://manual-archive.example")
        try store.setArchived(true, ids: [bookmark.id])

        let model = BookmarksModel(
            store: store,
            usageStore: UsageStore(rootDirectory: root)
        )
        guard let archived = model.bookmarks.first(where: { $0.id == bookmark.id }) else {
            throw SmokeTestError.failure("expected manually archived bookmark to load")
        }

        try expect(
            model.isEffectivelyArchived(archived),
            "expected manual archive state to remain effective when auto archive is disabled"
        )
        try expect(
            model.visibleUngroupedSections(sortMode: .name).isEmpty,
            "expected manually archived bookmark to stay out of visible bookmark sections"
        )
        try expect(
            model.menuRenderSections().allSatisfy { section in
                !section.bookmarks.contains(where: { $0.id == bookmark.id })
            },
            "expected manually archived bookmark to stay out of the menu"
        )

        try expect(
            model.setArchived(false, for: bookmark.id) == nil,
            "expected manually archived bookmark to be restorable while auto archive is disabled"
        )
        try expect(
            model.visibleUngroupedSections(sortMode: .name)
                .flatMap(\.bookmarks)
                .contains(where: { $0.id == bookmark.id }),
            "expected restored bookmark to return to visible bookmark sections"
        )
    }

    private static func testPinnedBookmarkPersistence() throws {
        let store = BookmarkStore(rootDirectory: try temporaryDirectory())
        let bookmark = try store.add(title: "Pinned", url: "https://pinned.example")

        try store.setPinned(true, ids: [bookmark.id])
        var loaded = try store.bookmarks()
        try expect(loaded.first { $0.id == bookmark.id }?.isPinned == true, "expected pinned state to persist")
        let payload = try loadVaultPayload(root: store.rootDirectory)
        try expect(payload.bookmarks.first { $0.id == bookmark.id }?.isPinned == true, "expected payload to include pinned state")
        var state = BookmarkStateStore(rootDirectory: store.rootDirectory).load()
        try expect(state.pinnedIds == [bookmark.id], "expected pinned id in bookmark_state")

        try store.setPinned(false, ids: [bookmark.id])
        loaded = try store.bookmarks()
        try expect(loaded.first { $0.id == bookmark.id }?.isPinned == false, "expected unpin to clear runtime state")
        state = BookmarkStateStore(rootDirectory: store.rootDirectory).load()
        try expect(state.pinnedIds.isEmpty, "expected unpin to clear pinned state")
    }

    @MainActor
    private static func testLibrarySectionsPrioritizePinnedBookmarks() throws {
        let root = try temporaryDirectory()
        let store = BookmarkStore(rootDirectory: root)
        let pinned = try store.add(title: "YouTube 订阅", url: "https://www.youtube.com")
        let ungrouped = try store.add(title: "Plain", url: "https://plain.example")
        try store.setPinned(true, ids: [pinned.id])

        let model = BookmarksModel(
            store: store,
            usageStore: UsageStore(rootDirectory: root)
        )
        let sections = model.bookmarkLibrarySections(
            for: model.bookmarks,
            pinnedSortMode: .name,
            collectionSortMode: .name,
            ungroupedSortMode: .name
        )

        try expect(
            sections.first?.title == "置顶 (1)",
            "expected pinned candidates to be rendered before ungrouped candidates"
        )
        try expect(
            sections.first?.bookmarks.map(\.id) == [pinned.id],
            "expected pinned candidate to stay in the pinned section"
        )
        let ungroupedSection = sections.first { $0.title == "未分组 (1)" }
        try expect(
            ungroupedSection?.bookmarks.map(\.id) == [ungrouped.id],
            "expected ungrouped section to exclude pinned bookmarks"
        )
    }

    private static func testBookmarkSearchMatcherSupportsPinyin() throws {
        let bookmark = Bookmark(title: "哔哩哔哩", url: "https://www.bilibili.com")

        try expect(
            BookmarkSearchMatcher.matches(bookmark: bookmark, query: "bili"),
            "expected collapsed pinyin to match Chinese title"
        )
        try expect(
            BookmarkSearchMatcher.matches(bookmark: bookmark, query: "bi li"),
            "expected spaced pinyin to match Chinese title"
        )
        try expect(
            BookmarkSearchMatcher.matches(bookmark: bookmark, query: "blbl"),
            "expected pinyin initials to match Chinese title"
        )
        try expect(
            BookmarkSearchMatcher.matches(bookmark: bookmark, query: "bilibili.com"),
            "expected existing URL matching to keep working"
        )
    }

    private static func testNativeBookmarkListFirstBookmarkRowSkipsHeaders() throws {
        let bookmark = Bookmark(title: "YouTube", url: "https://www.youtube.com")
        let sections = [
            BookmarkListSection(title: "置顶 (1)", bookmarks: [bookmark])
        ]

        try expect(
            NativeBookmarkSelectionResolver.firstBookmarkRowIndex(in: sections.flattenedItems) == 1,
            "expected keyboard focus to skip the section header and select the first bookmark row"
        )
        try expect(
            NativeBookmarkSelectionResolver.firstBookmarkRowIndex(in: [
                BookmarkListSection(title: "没有结果", bookmarks: [])
            ].flattenedItems) == nil,
            "expected no selectable row when sections contain no bookmarks"
        )
    }

    @MainActor
    private static func testMenuBarSearchKeyCommandHandlesEscapeAndEnterOnly() throws {
        try expect(
            MenuBarSearchKeyCommand.command(
                for: keyEvent(keyCode: UInt16(kVK_Escape), characters: "\u{1b}"),
                hasMarkedText: false
            ) == .close,
            "expected Escape to close the menu bar search popover"
        )
        try expect(
            MenuBarSearchKeyCommand.command(
                for: keyEvent(keyCode: UInt16(kVK_Return), characters: "\r"),
                hasMarkedText: false
            ) == .open,
            "expected Return to open the current menu bar search result"
        )
        try expect(
            MenuBarSearchKeyCommand.command(
                for: keyEvent(
                    keyCode: UInt16(kVK_ANSI_KeypadEnter),
                    characters: "\r",
                    modifierFlags: .numericPad
                ),
                hasMarkedText: false
            ) == .open,
            "expected keypad Enter to open the current menu bar search result"
        )
        try expect(
            MenuBarSearchKeyCommand.command(
                for: keyEvent(keyCode: UInt16(kVK_Space), characters: " "),
                hasMarkedText: false
            ) == .passThrough,
            "expected Space to remain normal search-field input"
        )
        try expect(
            MenuBarSearchKeyCommand.command(
                for: keyEvent(keyCode: UInt16(kVK_Return), characters: "\r", modifierFlags: .command),
                hasMarkedText: false
            ) == .passThrough,
            "expected modified Return to pass through"
        )
        try expect(
            MenuBarSearchKeyCommand.command(
                for: keyEvent(keyCode: UInt16(kVK_Return), characters: "\r"),
                hasMarkedText: true
            ) == .passThrough,
            "expected Return during marked text composition to pass through"
        )
    }

    @MainActor
    private static func testNativeSearchFieldEnterUsesFieldEditorText() throws {
        var text = ""
        var enteredQuery: String?
        let binding = Binding<String>(
            get: { text },
            set: { text = $0 }
        )
        let coordinator = NativeSearchField.Coordinator(
            text: binding,
            onEscape: nil,
            onTab: nil,
            onEnter: { enteredQuery = $0 },
            onDownArrow: nil
        )
        let textView = NSTextView()
        textView.string = "youtube"

        let handled = coordinator.control(
            NSSearchField(),
            textView: textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        try expect(handled, "expected search field Enter command to be handled")
        try expect(text == "youtube", "expected Enter command to sync current field-editor text")
        try expect(enteredQuery == "youtube", "expected Enter callback to receive current field-editor text")
    }

    @MainActor
    private static func testNativeSearchFieldEscapeUsesFirstCommand() throws {
        var text = ""
        var closeCount = 0
        let binding = Binding<String>(
            get: { text },
            set: { text = $0 }
        )
        let coordinator = NativeSearchField.Coordinator(
            text: binding,
            onEscape: { closeCount += 1 },
            onTab: nil,
            onEnter: nil,
            onDownArrow: nil
        )
        let textView = NSTextView()
        textView.string = "foo bar"

        let handled = coordinator.control(
            NSSearchField(),
            textView: textView,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )

        try expect(handled, "expected search field Escape command to be handled")
        try expect(text == "foo bar", "expected Escape command to sync current field-editor text")
        try expect(closeCount == 1, "expected first Escape command to close exactly once")
    }

    @MainActor
    private static func testMenuBarSearchCommandBridgeOpensOnce() throws {
        let bridge = MenuBarSearchCommandBridge()
        var openCount = 0
        var openedQuery: String?
        bridge.openHandler = { query in
            openCount += 1
            openedQuery = query
        }

        bridge.open(query: "foo bar")

        try expect(openCount == 1, "expected menu bar search command bridge to open exactly once")
        try expect(openedQuery == "foo bar", "expected menu bar search command bridge to preserve query text")
    }

    @MainActor
    private static func testBookmarkMenuTableViewReturnOpensSelection() throws {
        let delegate = BookmarkMenuTableViewDelegateSpy()
        let tableView = BookmarkMenuTableView()
        tableView.menuDelegate = delegate

        tableView.keyDown(with: keyEvent(keyCode: UInt16(kVK_Return), characters: "\r"))
        tableView.keyDown(with: keyEvent(
            keyCode: UInt16(kVK_ANSI_KeypadEnter),
            characters: "\r",
            modifierFlags: .numericPad
        ))

        try expect(delegate.openSelectionCount == 2, "expected Return and keypad Enter to open selected row")
    }

    @MainActor
    private static func testBookmarkSearchCandidatesExcludeHiddenAndIncludeArchived() throws {
        let root = try temporaryDirectory()
        let store = BookmarkStore(rootDirectory: root)
        let visible = try store.add(title: "Target Visible", url: "https://visible.example")
        let hidden = try store.add(title: "Target Hidden", url: "https://hidden.example", isHidden: true)
        let archived = try store.add(title: "Target Archived", url: "https://archived.example")
        try store.setArchived(true, ids: [archived.id])

        let model = BookmarksModel(
            store: store,
            usageStore: UsageStore(rootDirectory: root)
        )
        let resultIds = Set(model.searchBookmarks(matching: "target").map(\.id))

        try expect(resultIds.contains(visible.id), "expected visible search hit")
        try expect(!resultIds.contains(hidden.id), "expected hidden bookmarks to be excluded from search")
        try expect(resultIds.contains(archived.id), "expected archived bookmarks to remain searchable")
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

    private static func testEmptyBookmarkLoadCreatesEmptyVaultPayload() throws {
        let root = try temporaryDirectory()
        let loaded = try BookmarkStore(rootDirectory: root).bookmarks()
        try expect(loaded.isEmpty, "expected empty bookmark file to load as empty")
        let payload = try loadVaultPayload(root: root)
        try expect(payload.bookmarks.isEmpty, "expected empty vault payload")
        try expect(payload.groups.isEmpty, "expected empty vault groups")
    }

    private static func testUsageStoreCacheInvalidation() throws {
        let root = try temporaryDirectory()
        let bookmark = try BookmarkStore(rootDirectory: root).add(title: "Used", url: "https://used.example")
        let store = UsageStore(rootDirectory: root)
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)

        store.saveAll([bookmark.id: UsageRecord(count: 1, lastClickedAt: firstDate)])
        try expect(store.record(for: bookmark.id)?.count == 1, "expected initial usage count")

        var payload = try loadVaultPayload(root: root)
        payload.bookmarks = payload.bookmarks.map { record in
            var record = record
            record.usage = UsageRecord(count: 2, lastClickedAt: secondDate)
            return record
        }
        try saveVaultPayload(payload, root: root)

        // Stores over the same root share one payload cache: an in-process
        // write through any store is immediately visible, no invalidation
        // step needed.
        try expect(store.record(for: bookmark.id)?.count == 2, "expected shared cache to reflect in-process write")
        store.invalidateCache()
        let reloaded = store.record(for: bookmark.id)
        try expect(reloaded?.count == 2, "expected usage count after invalidation")
        try expect(reloaded?.lastClickedAt == secondDate, "expected usage date after invalidation")

        store.updateRootDirectory(try temporaryDirectory())
        try expect(store.record(for: bookmark.id) == nil, "expected root change to clear usage cache")
    }

    private static func testBookmarkStoreCacheInvalidation() throws {
        let root = try temporaryDirectory()
        let store = BookmarkStore(rootDirectory: root)
        _ = try store.add(title: "Cached", url: "https://cached.example")
        try expect(try store.bookmarks().map(\.title) == ["Cached"], "expected initial cached bookmark")

        var payload = try loadVaultPayload(root: root)
        payload.bookmarks = payload.bookmarks.map { record in
            var record = record
            record.title = "Externally Edited"
            return record
        }
        try saveVaultPayload(payload, root: root)

        // In-process writes through any store are immediately visible via the
        // shared per-root payload cache.
        try expect(try store.bookmarks().map(\.title) == ["Externally Edited"], "expected shared cache to reflect in-process write")
        store.invalidateCache()
        try expect(try store.bookmarks().map(\.title) == ["Externally Edited"], "expected bookmark reload after invalidation")

        let newRoot = try temporaryDirectory()
        store.updateRootDirectory(newRoot)
        try expect(try store.bookmarks().isEmpty, "expected root change to clear bookmark cache")
    }

    private static func testVaultDirectoryIsMarkedAsPackage() throws {
        let root = try temporaryDirectory()
            .appendingPathComponent(ObeliskPrivateStorage.vaultDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        ObeliskPrivateStorage.markVaultDirectoryAsPackageIfNeeded(root)

        let values = try root.resourceValues(forKeys: [.isPackageKey])
        try expect(values.isPackage == true, "expected vault directory to be marked as a Finder package")
    }

    private static func testVaultPayloadUsesVaultRoot() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        LocalJSONEncryption.isEnabled = false
        let store = BookmarkStore(rootDirectory: root)
        _ = try store.add(title: "Plain", url: "https://plain.example")

        let payloadURL = ObeliskVaultStore(rootDirectory: root).payloadURL
        try expect(store.fileURL == payloadURL, "expected active bookmark file to be the v2 payload")
        try expect(FileManager.default.fileExists(atPath: payloadURL.path), "expected encrypted payload in vault root")
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
    private static func testTitleOptimizationTranslationPrompt() throws {
        let translationOffPrompt = TitleOptimizer.systemPrompt(
            translateNonChineseTitles: false
        )
        try expect(
            translationOffPrompt.contains("Prefer the user's language when obvious from the title or URL."),
            "expected translation-off prompt to preserve source language preference"
        )
        try expect(
            !translationOffPrompt.contains("TRANSLATE_NON_CHINESE_TO_CHINESE"),
            "expected translation-off prompt not to force Chinese translation"
        )
        try expect(
            !translationOffPrompt.contains("Do not return an English-only title"),
            "expected translation-off prompt not to reject English-only titles"
        )

        let translationOnPrompt = TitleOptimizer.systemPrompt(
            translateNonChineseTitles: true
        )
        try expect(
            translationOnPrompt.contains("Prefer the user's language when obvious from the title or URL."),
            "expected translation-on prompt to keep source language preference"
        )
        try expect(
            translationOnPrompt.contains("Translation preference:"),
            "expected translation-on prompt to use translation preference wording"
        )
        try expect(
            !translationOnPrompt.contains("TRANSLATE_NON_CHINESE_TO_CHINESE"),
            "expected translation-on prompt not to force mandatory Chinese mode"
        )
        try expect(
            !translationOnPrompt.contains("MUST contain natural Chinese"),
            "expected translation-on prompt not to require Chinese text"
        )
        try expect(
            !translationOnPrompt.contains("Translate generic descriptive words, categories"),
            "expected translation-on prompt not to invent category descriptors"
        )
        try expect(
            translationOnPrompt.contains("when it is reasonable"),
            "expected translation-on prompt to translate only when reasonable"
        )
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

    @MainActor
    private static func testBookmarksModelTitleOptimizationOutcomeIncludesUpdatedTitle() async throws {
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
        let bookmark = try store.add(title: "Raw Optimizer Title", url: "https://outcome-title.example")
        let optimizer = StubTitleOptimizer(response: [
            bookmark.id: "Optimized Outcome Title"
        ])
        let model = BookmarksModel(
            store: store,
            usageStore: UsageStore(rootDirectory: root),
            titleOptimizer: optimizer
        )

        let outcome = await model.optimizeTitleDetails(bookmarkIds: [bookmark.id])
        try expect(outcome.message == "已优化 1 个标题", "expected outcome to preserve legacy optimization message")
        try expect(outcome.optimizedTitles == ["Optimized Outcome Title"], "expected outcome to expose updated title")

        let legacyMessage = await model.optimizeTitles(bookmarkIds: [bookmark.id])
        try expect(legacyMessage == "没有需要优化的标题", "expected legacy string API to remain available")
    }

    private static func testBookmarkIntelligenceAutomaticOptions() throws {
        let defaults = UserDefaults.standard
        let restoredDefaults = capturedDefaults(
            keys: [
                TitleOptimizationPreferences.autoOptimizeNewBookmarksKey,
                BookmarkAutoGroupingPreferences.autoGroupNewBookmarksKey
            ],
            defaults: defaults
        )
        defer {
            restoreDefaults(restoredDefaults, defaults: defaults)
        }

        let bookmark = Bookmark(title: "Visible", url: "https://visible.example")
        for optimizeTitles in [false, true] {
            for autoGroup in [false, true] {
                defaults.set(
                    optimizeTitles,
                    forKey: TitleOptimizationPreferences.autoOptimizeNewBookmarksKey
                )
                defaults.set(
                    autoGroup,
                    forKey: BookmarkAutoGroupingPreferences.autoGroupNewBookmarksKey
                )
                let options = BookmarkIntelligenceOptimizationOptions.automatic(
                    for: bookmark,
                    defaults: defaults
                )
                try expect(
                    options == BookmarkIntelligenceOptimizationOptions(
                        optimizeTitles: optimizeTitles,
                        autoGroup: autoGroup
                    ),
                    "expected automatic bookmark optimization toggles to remain independent"
                )
            }
        }
    }

    @MainActor
    private static func testBookmarksModelCombinedOptimizationUsesUpdatedTitles() async throws {
        let defaults = UserDefaults.standard
        let restoredDefaults = capturedDefaults(
            keys: [BookmarksModel.aiFeaturesEnabledKey],
            defaults: defaults
        )
        defer {
            restoreDefaults(restoredDefaults, defaults: defaults)
        }
        defaults.set(true, forKey: BookmarksModel.aiFeaturesEnabledKey)

        let root = try temporaryDirectory()
        let store = BookmarkStore(rootDirectory: root)
        let first = try store.add(title: "First Original", url: "https://first.example")
        let second = try store.add(title: "Second Original", url: "https://second.example")
        let titleOptimizer = StubTitleOptimizer(response: [
            first.id: "First Optimized",
            second.id: "Second Optimized"
        ])
        let groupOptimizer = StubBookmarkGroupOptimizer(response: [
            first.id: "开发",
            second.id: "开发"
        ])
        let model = BookmarksModel(
            store: store,
            usageStore: UsageStore(rootDirectory: root),
            titleOptimizer: titleOptimizer,
            groupOptimizer: groupOptimizer
        )
        try expect(model.createCollection(name: "开发") == nil, "expected collection setup")

        let outcome = await model.optimizeBookmarks(
            options: BookmarkIntelligenceOptimizationOptions(
                optimizeTitles: true,
                autoGroup: true
            )
        )

        try expect(
            Set(titleOptimizer.candidateIDs) == [first.id, second.id],
            "expected an empty combined scope to optimize all eligible titles"
        )
        try expect(
            Set(groupOptimizer.candidateTitles) == ["First Optimized", "Second Optimized"],
            "expected grouping to receive titles after title optimization"
        )
        try expect(outcome.titleOptimization?.status == .changed, "expected title changes")
        try expect(outcome.autoGrouping?.status == .changed, "expected grouping changes")
        try expect(outcome.didChange, "expected combined optimization to report success")
        try expect(
            outcome.summary == "优化标题 2 个；自动分组 2 个",
            "expected one combined batch summary"
        )
    }

    private static func testBookmarkIntelligenceOutcomeSummary() throws {
        let partialSuccess = BookmarkIntelligenceOptimizationOutcome(
            titleOptimization: TitleOptimizationOutcome(
                message: "已优化 1 个标题",
                optimizedTitles: ["Optimized"],
                status: .changed
            ),
            autoGrouping: BookmarkAutoGroupingOutcome(
                message: "分组请求失败",
                groupedCount: 0,
                placements: [],
                status: .failed
            )
        )
        try expect(partialSuccess.didChange, "expected any changed step to make the combined result successful")
        try expect(
            partialSuccess.summary == "标题「Optimized」；分组请求失败",
            "expected partial failures to remain visible in the combined summary"
        )

        let noChanges = BookmarkIntelligenceOptimizationOutcome(
            titleOptimization: TitleOptimizationOutcome(
                message: "没有需要优化的标题",
                optimizedTitles: []
            ),
            autoGrouping: BookmarkAutoGroupingOutcome(
                message: "没有需要自动分组的书签",
                groupedCount: 0,
                placements: []
            )
        )
        try expect(!noChanges.didChange, "expected an all-no-change result to be unsuccessful")
        try expect(
            noChanges.summary == "没有需要优化的标题；没有需要自动分组的书签",
            "expected both no-change reasons in one summary"
        )
    }

    @MainActor
    private static func testBookmarksModelAutoGroupsUngroupedBookmarks() async throws {
        let defaults = UserDefaults.standard
        let restoredDefaults = capturedDefaults(
            keys: [
                BookmarksModel.aiFeaturesEnabledKey
            ],
            defaults: defaults
        )
        defer {
            restoreDefaults(restoredDefaults, defaults: defaults)
        }

        defaults.set(true, forKey: BookmarksModel.aiFeaturesEnabledKey)

        let root = try temporaryDirectory()
        let store = BookmarkStore(rootDirectory: root)
        let docs = try store.add(title: "Swift Concurrency Guide", url: "https://developer.apple.com/documentation/swift/concurrency")
        let recipe = try store.add(title: "Sourdough Starter Notes", url: "https://example.com/sourdough")
        let groupOptimizer = StubBookmarkGroupOptimizer(response: [
            docs.id: "开发",
            recipe.id: "食谱"
        ])
        let model = BookmarksModel(
            store: store,
            usageStore: UsageStore(rootDirectory: root),
            titleOptimizer: StubTitleOptimizer(response: [:]),
            groupOptimizer: groupOptimizer
        )
        try expect(model.createCollection(name: "开发") == nil, "expected existing collection setup")

        let outcome = await model.autoGroupBookmarks()
        try expect(outcome.groupedCount == 1, "expected only bookmark with an existing suggested group to be assigned")
        try expect(outcome.message == "已自动分组 1 个书签", "expected grouping summary")
        let placementById = Dictionary(uniqueKeysWithValues: outcome.placements.map { ($0.bookmarkId, $0) })
        try expect(placementById[docs.id]?.groupName == "开发", "expected existing group name in outcome")
        try expect(placementById[recipe.id] == nil, "expected non-existing group suggestion to be ignored")
        try expect(groupOptimizer.existingCollectionNames == ["开发"], "expected existing groups to be sent to optimizer")

        let collectionByName = Dictionary(uniqueKeysWithValues: model.collections.map { ($0.name, $0.id) })
        try expect(model.collectionId(for: docs.id) == collectionByName["开发"], "expected existing collection to be reused")
        try expect(collectionByName["食谱"] == nil, "expected auto grouping not to create a new collection")
        try expect(model.collectionId(for: recipe.id) == nil, "expected bookmark with non-existing group suggestion to remain ungrouped")
    }

    @MainActor
    private static func testBookmarksModelAutoGroupingSkipsGroupedPinnedAndHiddenBookmarks() async throws {
        let defaults = UserDefaults.standard
        let restoredDefaults = capturedDefaults(
            keys: [
                BookmarksModel.aiFeaturesEnabledKey
            ],
            defaults: defaults
        )
        defer {
            restoreDefaults(restoredDefaults, defaults: defaults)
        }

        defaults.set(true, forKey: BookmarksModel.aiFeaturesEnabledKey)

        let root = try temporaryDirectory()
        let store = BookmarkStore(rootDirectory: root)
        let grouped = try store.add(title: "Grouped", url: "https://grouped.example")
        let pinned = try store.add(title: "Pinned", url: "https://pinned.example")
        let hidden = try store.add(title: "Hidden", url: "https://hidden.example", isHidden: true)
        let ungrouped = try store.add(title: "Ungrouped", url: "https://ungrouped.example")
        try store.setPinned(true, ids: [pinned.id])

        let groupOptimizer = StubBookmarkGroupOptimizer(response: [
            grouped.id: "工作",
            pinned.id: "置顶",
            hidden.id: "隐藏",
            ungrouped.id: "阅读"
        ])
        let model = BookmarksModel(
            store: store,
            usageStore: UsageStore(rootDirectory: root),
            titleOptimizer: StubTitleOptimizer(response: [:]),
            groupOptimizer: groupOptimizer
        )
        try expect(model.createCollection(name: "工作") == nil, "expected collection setup")
        try expect(model.createCollection(name: "阅读") == nil, "expected target collection setup")
        let workId = model.collections.first { $0.name == "工作" }?.id
        try expect(workId != nil, "expected work collection")
        try expect(model.setBookmarkCollection(bookmarkIds: [grouped.id], collectionId: workId) == nil, "expected manual grouping setup")

        let outcome = await model.autoGroupBookmarks()
        try expect(outcome.groupedCount == 1, "expected only visible unpinned ungrouped bookmark to be assigned")
        try expect(outcome.singleBookmarkDescription == "已归入「阅读」", "expected single existing-group formatter")
        try expect(groupOptimizer.candidateIDs == [ungrouped.id], "expected grouped, pinned, and hidden bookmarks to be skipped")
        try expect(model.collectionId(for: grouped.id) == workId, "expected existing membership to be preserved")
        try expect(model.collectionId(for: pinned.id) == nil, "expected pinned bookmark to remain outside collections")
        try expect(model.collectionId(for: hidden.id) == nil, "expected hidden bookmark to remain outside collections")
        try expect(model.collectionId(for: ungrouped.id) != nil, "expected ungrouped bookmark to receive a collection")
    }

    private static func testBookmarkAutoGroupingSingleDescription() throws {
        let id = UUID()
        let reused = BookmarkAutoGroupingOutcome(
            message: "已自动分组 1 个书签",
            groupedCount: 1,
            placements: [
                AutoGroupedBookmarkPlacement(bookmarkId: id, groupName: "开发")
            ]
        )
        try expect(reused.singleBookmarkDescription == "已归入「开发」", "expected existing group popover copy")
    }

    private static func testUsageGroupingFilters() throws {
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
        let usage = [
            frequent.id: UsageRecord(count: 5, lastClickedAt: now),
            lowCount.id: UsageRecord(count: 1, lastClickedAt: now),
            staleLowScore.id: UsageRecord(count: 2, lastClickedAt: now.addingTimeInterval(-60 * 86_400))
        ]

        let bookmarks = [frequent, lowCount, legacy]
        try expect(
            UsageStore().topFrequent(
                among: bookmarks + [staleLowScore],
                usage: usage,
                limit: 5,
                now: now
            ).map(\.id) == [frequent.id],
            "expected only count >= 3 bookmark in frequent group"
        )
        try expect(
            UsageStore().recent(among: bookmarks, limit: 5).map(\.id) == [lowCount.id, frequent.id],
            "expected recent group to skip legacy dates"
        )
        try expect(
            UsageStore.frecencySorted(
                among: [noUsageBeta, staleLowScore, frequent, lowCount, legacy, noUsageAlpha],
                usage: usage,
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
        try expect(rawText.contains("obelisk.encrypted-json.v1"), "expected encrypted envelope marker")
        try expect(!rawText.contains("private.example"), "expected encrypted file to hide bookmark URL")
        try expect(store.fileURL.lastPathComponent == ObeliskVaultStore.payloadFileName, "expected bookmark store to use v2 payload")
        try expect(store.fileURL.deletingLastPathComponent() == root, "expected encrypted bookmark store to use vault root")
        try expect(try store.bookmarks().map(\.id) == [bookmark.id], "expected encrypted bookmark to read back")

        LocalJSONEncryption.isEnabled = false
        let database = try store.load()
        try store.save(database)
        let stillEncrypted = try String(contentsOf: store.fileURL, encoding: .utf8)
        try expect(stillEncrypted.contains("obelisk.encrypted-json.v1"), "expected v2 payload to remain encrypted when legacy preference is disabled")
        try expect(!stillEncrypted.contains("private.example"), "expected v2 payload to keep hiding bookmark URL")
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
        let raw = try Data(contentsOf: stateURL)
        let rawText = String(decoding: raw, as: UTF8.self)

        try expect(stateURL.lastPathComponent == ObeliskVaultStore.payloadFileName, "expected bookmark state to use v2 payload")
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

    private static func testBookmarkGroupsEncryptionRoundTrip() throws {
        let previous = LocalJSONEncryption.isEnabled
        defer { LocalJSONEncryption.isEnabled = previous }

        let root = try temporaryDirectory()
        LocalJSONEncryption.isEnabled = false
        let bookmark = try BookmarkStore(rootDirectory: root).add(title: "Grouped", url: "https://grouped.example")
        let groupStore = BookmarkGroupStore(rootDirectory: root)
        var workID: UUID?

        try groupStore.update { database in
            let work = BookmarkCollection(name: "工作", sortOrder: 0)
            workID = work.id
            database.collections = [work]
            database.membershipByBookmarkId[bookmark.id] = work.id
        }

        let loaded = groupStore.load()
        try expect(loaded.collections.count == 1, "expected collection count to round-trip")
        try expect(loaded.collections.first?.name == "工作", "expected collection name to round-trip")
        try expect(loaded.membershipByBookmarkId[bookmark.id] == workID, "expected membership to round-trip")

        let groupsURL = groupStore.fileURL
        let rawText = try String(contentsOf: groupsURL, encoding: .utf8)
        try expect(rawText.contains("obelisk.encrypted-json.v1"), "expected groups payload envelope marker")
        try expect(!rawText.contains("工作"), "expected groups payload to hide collection name")
    }

    private static func testEncryptionKeyMissingWhenEncryptedPayloadsExist() throws {
        let root = try temporaryDirectory()
        let service = try isolatedEncryptionKeychainService()
        defer { deleteKeychainItems(service: service) }

        let keyStore = KeychainEncryptionKeyStore(encryptedPayloadsRoot: root, keychainService: service)
        let codec = SecureJSONFileCodec(keyStore: keyStore)
        let encryptedURL = root.appendingPathComponent(ObeliskVaultStore.payloadFileName)
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
        let encryptedURL = root.appendingPathComponent(ObeliskVaultStore.payloadFileName)
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

        let backupParent = root.appendingPathComponent("Downloads", isDirectory: true)
        let result = try ObeliskPlaintextDataBackup.createBackup(
            in: root,
            destinationParent: backupParent
        )
        try expect(result.destinationURL.lastPathComponent.hasPrefix("Backup-"), "expected dated backup folder name")
        try expect(
            result.destinationURL.deletingLastPathComponent() == backupParent,
            "expected plaintext backup to live directly inside the selected directory"
        )
        let payloadURL = result.destinationURL.appendingPathComponent("payload.json")
        try expect(FileManager.default.fileExists(atPath: payloadURL.path), "expected plaintext payload backup")
        try expect(
            !FileManager.default.fileExists(atPath: result.destinationURL.appendingPathComponent("Data").path),
            "expected plaintext backup not to wrap files in Data"
        )
        let raw = try String(contentsOf: payloadURL, encoding: .utf8)
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

        oldDefaults.set(false, forKey: ObeliskAppDefaults.openHiddenBookmarksIncognitoKey)
        oldDefaults.set("legacy-window-id", forKey: "diaIncognitoWindowID")

        ObeliskAppDefaults.register(in: freshDefaults)

        try expect(
            freshDefaults.bool(forKey: ObeliskAppDefaults.openHiddenBookmarksIncognitoKey),
            "expected fresh app defaults to enable incognito hidden bookmarks"
        )
        try expect(
            freshDefaults.bool(forKey: LocalJSONEncryption.enabledKey),
            "expected fresh app defaults to enable local JSON encryption"
        )
        try expect(
            freshDefaults.bool(forKey: LocalJSONEncryption.disabledByAuthenticatedUserKey) == false,
            "expected fresh app defaults not to mark encryption as user-disabled"
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
            freshDefaults.bool(forKey: BookmarkAutoGroupingPreferences.autoGroupNewBookmarksKey) == false,
            "expected fresh app defaults to keep new-bookmark auto grouping off"
        )
        try expect(
            HiddenBookmarkKeywordExclusion.keywords(in: freshDefaults).isEmpty,
            "expected fresh app defaults to start with no hidden bookmark exclusion keywords"
        )
        try expect(
            oldDefaults.bool(forKey: ObeliskAppDefaults.openHiddenBookmarksIncognitoKey) == false,
            "expected legacy incognito preference to stay isolated"
        )
    }

    private static func testLocalJSONEncryptionDefaultsForceProductionEncryption() throws {
        let legacyFalseSuiteName = "com.eli.Obelisk.legacy-false.test.\(UUID().uuidString)"
        let authenticatedDisabledSuiteName = "com.eli.Obelisk.auth-disabled.test.\(UUID().uuidString)"
        let reenabledSuiteName = "com.eli.Obelisk.reenabled.test.\(UUID().uuidString)"
        let uiTestingSuiteName = "com.eli.Obelisk.ui-testing.test.\(UUID().uuidString)"
        guard
            let legacyFalseDefaults = UserDefaults(suiteName: legacyFalseSuiteName),
            let authenticatedDisabledDefaults = UserDefaults(suiteName: authenticatedDisabledSuiteName),
            let reenabledDefaults = UserDefaults(suiteName: reenabledSuiteName),
            let uiTestingDefaults = UserDefaults(suiteName: uiTestingSuiteName)
        else {
            throw SmokeTestError.failure("expected encryption defaults test suites")
        }
        defer {
            legacyFalseDefaults.removePersistentDomain(forName: legacyFalseSuiteName)
            authenticatedDisabledDefaults.removePersistentDomain(forName: authenticatedDisabledSuiteName)
            reenabledDefaults.removePersistentDomain(forName: reenabledSuiteName)
            uiTestingDefaults.removePersistentDomain(forName: uiTestingSuiteName)
        }

        legacyFalseDefaults.set(false, forKey: LocalJSONEncryption.enabledKey)
        ObeliskAppDefaults.register(in: legacyFalseDefaults)
        try expect(
            legacyFalseDefaults.bool(forKey: LocalJSONEncryption.enabledKey),
            "expected unauthenticated legacy disabled encryption default to be corrected"
        )
        try expect(
            legacyFalseDefaults.bool(forKey: LocalJSONEncryption.disabledByAuthenticatedUserKey) == false,
            "expected corrected legacy default not to mark encryption as user-disabled"
        )

        authenticatedDisabledDefaults.set(false, forKey: LocalJSONEncryption.enabledKey)
        authenticatedDisabledDefaults.set(true, forKey: LocalJSONEncryption.disabledByAuthenticatedUserKey)
        ObeliskAppDefaults.register(in: authenticatedDisabledDefaults)
        try expect(
            authenticatedDisabledDefaults.bool(forKey: LocalJSONEncryption.enabledKey),
            "expected authenticated user-disabled encryption setting to be corrected"
        )
        try expect(
            authenticatedDisabledDefaults.bool(forKey: LocalJSONEncryption.disabledByAuthenticatedUserKey) == false,
            "expected authenticated user-disabled marker to be cleared"
        )

        reenabledDefaults.set(true, forKey: LocalJSONEncryption.enabledKey)
        reenabledDefaults.set(true, forKey: LocalJSONEncryption.disabledByAuthenticatedUserKey)
        ObeliskAppDefaults.register(in: reenabledDefaults)
        try expect(
            reenabledDefaults.bool(forKey: LocalJSONEncryption.enabledKey),
            "expected re-enabled encryption setting to stay enabled"
        )
        try expect(
            reenabledDefaults.bool(forKey: LocalJSONEncryption.disabledByAuthenticatedUserKey) == false,
            "expected re-enabled encryption to clear authenticated disable marker"
        )

        uiTestingDefaults.set(false, forKey: LocalJSONEncryption.enabledKey)
        ObeliskAppDefaults.register(
            in: uiTestingDefaults,
            preservesUnauthenticatedDisabledEncryption: true
        )
        try expect(
            uiTestingDefaults.bool(forKey: LocalJSONEncryption.enabledKey) == false,
            "expected explicit UI testing override to preserve disabled encryption"
        )
        try expect(
            uiTestingDefaults.bool(forKey: LocalJSONEncryption.disabledByAuthenticatedUserKey) == false,
            "expected UI testing override not to mark encryption as user-disabled"
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
        let bookmark = try BookmarkStore(rootDirectory: root).add(title: "Member", url: "https://member.example")
        let groupStore = BookmarkGroupStore(rootDirectory: root)
        var workID: UUID?

        try groupStore.update { database in
            let work = BookmarkCollection(name: "工作", sortOrder: 0)
            workID = work.id
            database.collections = [work]
        }

        try groupStore.update { database in
            database.membershipByBookmarkId[bookmark.id] = workID
        }

        let loaded = groupStore.load()
        try expect(loaded.collections.count == 1, "expected one collection")
        try expect(loaded.collections.first?.name == "工作", "expected collection name to round-trip")
        try expect(loaded.membershipByBookmarkId[bookmark.id] == workID, "expected membership to round-trip")

        try groupStore.removeMembership(for: [bookmark.id])
        try expect(groupStore.load().membershipByBookmarkId[bookmark.id] == nil, "expected membership removal")
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func backupDirectories(in root: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.filter { url in
            guard url.lastPathComponent.hasPrefix("Backup-") else {
                return false
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
        }
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

    private static func loadVaultPayload(root: URL) throws -> ObeliskVaultPayload {
        try ObeliskVaultStore(rootDirectory: root).loadPayload()
    }

    private static func saveVaultPayload(_ payload: ObeliskVaultPayload, root: URL) throws {
        try ObeliskVaultStore(rootDirectory: root).savePayload(payload)
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

private final class StubBookmarkGroupOptimizer: BookmarkGroupingOptimizing {
    private let response: [UUID: String]
    private(set) var candidateIDs: [UUID] = []
    private(set) var candidateTitles: [String] = []
    private(set) var existingCollectionNames: [String] = []

    init(response: [UUID: String]) {
        self.response = response
    }

    func suggestGroups(
        for candidates: [BookmarkGroupingCandidate],
        existingCollections: [BookmarkGroupingExistingCollection]
    ) async throws -> [UUID: String] {
        candidateIDs = candidates.map(\.id)
        candidateTitles = candidates.map(\.title)
        existingCollectionNames = existingCollections.map(\.name)
        return response
    }
}

@MainActor
private final class BookmarkMenuTableViewDelegateSpy: BookmarkMenuTableViewDelegate {
    private(set) var openSelectionCount = 0

    func bookmarkMenuTableView(_ tableView: BookmarkMenuTableView, shouldSelectContextRow row: Int) -> Bool {
        false
    }

    func bookmarkMenuTableView(_ tableView: BookmarkMenuTableView, menuForRow row: Int) -> NSMenu? {
        nil
    }

    func bookmarkMenuTableViewCopySelection(_ tableView: BookmarkMenuTableView) {}

    func bookmarkMenuTableViewEditSelection(_ tableView: BookmarkMenuTableView) {}

    func bookmarkMenuTableViewDeleteSelection(_ tableView: BookmarkMenuTableView) {}

    func bookmarkMenuTableViewOpenSelection(_ tableView: BookmarkMenuTableView) {
        openSelectionCount += 1
    }
}

private func keyEvent(
    keyCode: UInt16,
    characters: String,
    modifierFlags: NSEvent.ModifierFlags = []
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )!
}
