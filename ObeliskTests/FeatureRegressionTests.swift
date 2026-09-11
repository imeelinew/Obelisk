import AppKit
import Carbon.HIToolbox
import Foundation
import ObeliskCore
import ObeliskData
import ObeliskSync
import SwiftUI
import Testing
@testable import Obelisk

@Suite(.serialized)
struct FeatureRegressionTests {
    @MainActor
    @Test func cloudSyncStartsLocallyWithoutAConfiguredService() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskCloudSync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ObeliskCloudSyncDefaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let database = try ObeliskDatabase.open(
            rootDirectory: root,
            deviceID: UUID()
        )
        let controller = CloudSyncController(
            database: database,
            defaults: defaults,
            accessKeyStore: InMemoryAccessKeyStore()
        )

        await controller.start()
        #expect(!controller.isEnabled)
        #expect(!controller.isConfigured)
        #expect(controller.phase == .off)

        await controller.setEnabled(true)
        #expect(controller.phase == .notConfigured)

        await controller.setEnabled(false)
        #expect(controller.phase == .off)
    }

    @MainActor
    @Test func defaultRootDirectoryUsesApplicationSupportSyncFolder() {
        let previous = ProcessInfo.processInfo.environment["OBELISK_HOME"]
        unsetenv("OBELISK_HOME")
        defer {
            if let previous {
                setenv("OBELISK_HOME", previous, 1)
            }
        }

        let root = BookmarkStore.defaultRootDirectory()
        #expect(root.path.contains("/Library/Application Support/"))
        #expect(root.lastPathComponent == "Sync")
        #expect(root.deletingLastPathComponent().lastPathComponent == "com.eli.Obelisk")
    }

    @MainActor
    @Test func webURLValidationTrimsAndRejectsInvalidSchemes() async throws {
        try await withStore { store in
            let bookmark = try store.add(title: "Trimmed", url: "  https://trimmed.example/path  \n")
            #expect(bookmark.url == "https://trimmed.example/path")
            #expect(throws: BookmarkStoreError.self) {
                try store.add(title: "FTP", url: "ftp://example.com")
            }
            #expect(throws: BookmarkStoreError.self) {
                try store.add(title: "No Host", url: "https:foo")
            }
        }
    }

    @MainActor
    @Test func hiddenKeywordRulesApplyToAddUpdateAndReveal() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: HiddenBookmarkKeywordExclusion.storageKey)
        defer { restore(previous, key: HiddenBookmarkKeywordExclusion.storageKey, defaults: defaults) }
        defaults.set("private\nPRIVATE\n token ", forKey: HiddenBookmarkKeywordExclusion.storageKey)

        #expect(HiddenBookmarkKeywordExclusion.keywords(in: defaults) == ["private", "token"])
        #expect(HiddenBookmarkKeywordExclusion.matches(url: "https://example.com/access_token=1", defaults: defaults))

        try await withStore { store in
            let model = BookmarksModel(store: store)
            guard case .failure(let error) = model.addBookmark(
                title: "Blocked",
                url: "https://example.com/private",
                isHidden: false
            ) else {
                Issue.record("ordinary keyword-matched bookmark was accepted")
                return
            }
            #expect(error.localizedDescription == HiddenBookmarkKeywordExclusion.blockedBookmarkMessage)

            let hidden = try #require(try? model.addBookmark(
                title: "Hidden",
                url: "https://example.com/private",
                isHidden: true
            ).get())
            #expect(model.setHidden(false, for: hidden.id) == HiddenBookmarkKeywordExclusion.blockedBookmarkMessage)

            let visible = try #require(try? model.addBookmark(
                title: "Visible",
                url: "https://example.com/public",
                isHidden: false
            ).get())
            var changed = visible
            changed.url = "https://example.com/private/updated"
            #expect(model.update(changed) == HiddenBookmarkKeywordExclusion.blockedBookmarkMessage)
        }
    }

    @Test func pinyinSearchMatchesCollapsedSpacedAndInitialForms() {
        let bookmark = Bookmark(title: "哔哩哔哩", url: "https://www.bilibili.com")
        #expect(BookmarkSearchMatcher.matches(bookmark: bookmark, query: "bili"))
        #expect(BookmarkSearchMatcher.matches(bookmark: bookmark, query: "bi li"))
        #expect(BookmarkSearchMatcher.matches(bookmark: bookmark, query: "blbl"))
        #expect(BookmarkSearchMatcher.matches(bookmark: bookmark, query: "bilibili.com"))
    }

    @Test func gridAndListUseTheSameChronologicalBookmarkOrder() {
        let newest = Bookmark(title: "Zulu", url: "https://newest.example", createdAt: Date(timeIntervalSince1970: 300))
        let sameTimeA = Bookmark(title: "Alpha", url: "https://alpha.example", createdAt: Date(timeIntervalSince1970: 200))
        let sameTimeZ = Bookmark(title: "Zulu", url: "https://zulu.example", createdAt: Date(timeIntervalSince1970: 200))
        let sections = BookmarkGridSection.dateSections(from: [sameTimeZ, newest, sameTimeA])

        #expect(sections.flatMap(\.bookmarks).map(\.id) == [newest.id, sameTimeA.id, sameTimeZ.id])
        #expect(sections.listSections.flatMap(\.bookmarks).map(\.id) == sections.flatMap(\.bookmarks).map(\.id))
    }

    @Test func firstBookmarkSelectionSkipsSectionHeaders() {
        let bookmark = Bookmark(title: "YouTube", url: "https://youtube.com")
        #expect(NativeBookmarkSelectionResolver.firstBookmarkRowIndex(in: [
            BookmarkListSection(title: "今天", bookmarks: [bookmark])
        ].flattenedItems) == 1)
        #expect(NativeBookmarkSelectionResolver.firstBookmarkRowIndex(in: [
            BookmarkListSection(title: "没有结果", bookmarks: [])
        ].flattenedItems) == nil)
    }

    @Test func gridRangeSelectionUsesVisualOrderForItsFallbackAnchor() {
        let orderedIDs = [UUID(), UUID(), UUID(), UUID()]
        let selection = Set([orderedIDs[1], orderedIDs[3]])

        #expect(BookmarkGridSelectionResolver.stableAnchorID(
            orderedIDs: orderedIDs,
            selection: selection
        ) == orderedIDs[1])
        #expect(BookmarkGridSelectionResolver.stableAnchorID(
            orderedIDs: orderedIDs,
            selection: []
        ) == nil)
    }

    @Test func bookmarkFeedbackUsesDistinctTransientStates() {
        let kinds: [BookmarkFeedbackKind] = [.success, .hidden, .intelligence, .error]
        #expect(kinds.allSatisfy { $0.dismissalDelay == 5 })
    }

    @MainActor
    @Test func hiddenBookmarksSidebarMenuUsesTheConfiguredShortcut() {
        let target = HiddenBookmarksSidebarMenuActionStub()
        let item = ApplicationMenu.hiddenBookmarksSidebarMenuItem(
            target: target,
            action: #selector(HiddenBookmarksSidebarMenuActionStub.toggle(_:))
        )

        #expect(!item.isHidden)
        #expect(item.keyEquivalent == "h")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
        #expect(item.action == #selector(HiddenBookmarksSidebarMenuActionStub.toggle(_:)))
    }

    @Test func togglingHiddenBookmarksSidebarVisibilityFlipsStoredFlag() {
        let defaults = UserDefaults.standard
        let key = ObeliskAppDefaults.showHiddenBookmarksPageKey
        let previous = defaults.object(forKey: key)
        defer { restore(previous, key: key, defaults: defaults) }

        defaults.set(false, forKey: key)
        ObeliskAppDefaults.toggleShowHiddenBookmarksPage(in: defaults)
        #expect(defaults.bool(forKey: key))
        ObeliskAppDefaults.toggleShowHiddenBookmarksPage(in: defaults)
        #expect(!defaults.bool(forKey: key))
    }

    @MainActor
    @Test func menuItemFaviconsRemainVisibleAndUseBalancedRowHeight() {
        let menuItem = NSMenuItem(title: "Bookmark", action: nil, keyEquivalent: "")
        let oversizedFavicon = AppIcon.faviconPlaceholder(size: NSSize(width: 32, height: 32))

        AppIcon.setMenuItemFavicon(oversizedFavicon, on: menuItem)

        #expect(AppIcon.menuItemFaviconSize == NSSize(width: 16, height: 16))
        #expect(menuItem.image?.size == AppIcon.menuItemFaviconCanvasSize)
        #expect(oversizedFavicon.size == NSSize(width: 32, height: 32))
        if #available(macOS 27.0, *) {
            #expect(menuItem.preferredImageVisibility == .visible)
        }
    }

    @MainActor
    @Test func bookmarkCardsAndListsShareTheNativeContextMenuStructure() throws {
        let collectionID = UUID()
        var opened = false
        var assignedCollectionID: UUID?
        var deleted = false
        var configuration = NativeBookmarkContextMenuConfiguration()
        configuration.onOpen = { opened = true }
        configuration.onCopyURL = {}
        configuration.onEdit = {}
        configuration.onRevertTitleOptimization = {}
        configuration.onRetryTitleOptimization = {}
        configuration.collectionAssignOptions = [
            BookmarkCollectionAssignOption(title: "工作", collectionId: collectionID)
        ]
        configuration.onAssignCollection = { assignedCollectionID = $0 }
        configuration.hiddenStateActionTitle = "移到隐藏书签".obeliskLocalized
        configuration.hiddenStateSystemSymbolName = "eye.slash"
        configuration.onSetHidden = {}
        configuration.archiveStateActionTitle = "归档".obeliskLocalized
        configuration.archiveStateSystemSymbolName = "archivebox"
        configuration.onSetArchived = {}
        configuration.onDelete = { deleted = true }

        let controller = NativeBookmarkContextMenuController()
        let menu = try #require(controller.makeMenu(configuration: configuration))

        #expect(menu.items.map(\.isSeparatorItem) == [
            false, false, false,
            true, false, false, false,
            true, false,
            true, false,
            true, false
        ])
        #expect(menu.items[0].title == "打开".obeliskLocalized)
        #expect(menu.items[0].image != nil)
        #expect(!menu.items.contains { $0.title == "刷新 favicon".obeliskLocalized })
        #expect(menu.items[4].title == "移到分组".obeliskLocalized)
        #expect(menu.items[4].submenu?.items.map(\.title) == ["工作"])
        #expect(menu.items[6].title == "重新优化".obeliskLocalized)
        #expect(menu.items[12].title == "删除".obeliskLocalized)
        let destructiveTitle = try #require(menu.items[12].attributedTitle)
        #expect(destructiveTitle.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor == .systemRed)

        menu.delegate?.menuDidClose?(menu)
        menu.performActionForItem(at: 0)
        menu.items[4].submenu?.performActionForItem(at: 0)
        menu.performActionForItem(at: 12)
        #expect(opened)
        #expect(assignedCollectionID == collectionID)
        #expect(deleted)
    }

    @MainActor
    @Test func nativeContextMenuHostUsesTheOriginalAppKitEvent() throws {
        let menu = NSMenu()
        var receivedEvent: NSEvent?
        let eventView = NativeContextMenuEventView()
        eventView.menuProvider = { event in
            receivedEvent = event
            return menu
        }
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ))

        #expect(NativeContextMenuEventView.handlesContextMenuEvent(event))
        #expect(eventView.menu(for: event) === menu)
        #expect(receivedEvent === event)
    }

    @MainActor
    @Test func collectionCardHeadersAndListHeadersShareTheNativeContextMenuStructure() throws {
        var renamed = false
        var deleted = false
        let controller = NativeCollectionContextMenuController()
        let menu = try #require(controller.makeMenu(configuration: .init(
            onRename: { renamed = true },
            onDelete: { deleted = true }
        )))

        #expect(menu.items.map(\.isSeparatorItem) == [false, true, false])
        #expect(menu.items[0].title == "重命名分组".obeliskLocalized)
        #expect(menu.items[0].image != nil)
        #expect(menu.items[2].title == "删除分组".obeliskLocalized)
        let destructiveTitle = try #require(menu.items[2].attributedTitle)
        #expect(destructiveTitle.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor == .systemRed)

        menu.delegate?.menuDidClose?(menu)
        menu.performActionForItem(at: 0)
        menu.performActionForItem(at: 2)
        #expect(renamed)
        #expect(deleted)
    }

    @Test func enteringSearchPageCreatesANewFocusRequest() {
        let initialRequest = 4
        #expect(BookmarkManagerView.SearchFocusRequestResolver.resolve(
            current: initialRequest,
            selectedPage: .search
        ) == 5)
        #expect(BookmarkManagerView.SearchFocusRequestResolver.resolve(
            current: initialRequest,
            selectedPage: .bookmarks
        ) == initialRequest)
    }

    @MainActor
    @Test func nativeSearchFieldCommandsUseCurrentEditorText() {
        var text = ""
        var entered: String?
        var closes = 0
        let binding = Binding<String>(get: { text }, set: { text = $0 })
        let coordinator = NativeSearchField.Coordinator(
            text: binding,
            onEscape: { closes += 1 },
            onTab: nil,
            onEnter: { entered = $0 },
            onDownArrow: nil
        )
        let editor = NSTextView()
        editor.string = "youtube"
        #expect(coordinator.control(
            NSSearchField(),
            textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        #expect(text == "youtube")
        #expect(entered == "youtube")

        editor.string = "foo bar"
        #expect(coordinator.control(
            NSSearchField(),
            textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))
        #expect(text == "foo bar")
        #expect(closes == 1)
    }

    @MainActor
    @Test func nativeSearchFieldUsesInteractiveLiquidGlassChrome() {
        let searchField = NSSearchField()
        let glassView = NativeGlassSearchFieldView(searchField: searchField)

        #expect(glassView.style == .regular)
        #expect(glassView.cornerRadius == 13)
        #expect(glassView.contentView?.subviews.contains(searchField) == true)
        #expect(!searchField.isBezeled)
        #expect(!searchField.drawsBackground)
        if #available(macOS 27.0, *) {
            #expect(glassView.effectIsInteractive)
        }
    }

    @MainActor
    @Test func glassSearchFieldEditorAvoidsTheSearchIcon() {
        let searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 500, height: 30))
        let cell = NativeGlassSearchFieldCell(textCell: "")
        searchField.cell = cell
        searchField.controlSize = .large
        searchField.isBezeled = false
        searchField.drawsBackground = false
        let expectedFrame = cell.searchTextRect(forBounds: searchField.bounds)
        #expect(cell.isEditable)
        #expect(cell.isSelectable)

        let editingTextView = NSTextView()
        cell.edit(
            withFrame: searchField.bounds,
            in: searchField,
            editor: editingTextView,
            delegate: nil,
            event: nil
        )
        #expect(editingTextView.frame == expectedFrame)

        let selectingTextView = NSTextView()
        cell.select(
            withFrame: searchField.bounds,
            in: searchField,
            editor: selectingTextView,
            delegate: nil,
            start: 0,
            length: 0
        )
        #expect(selectingTextView.frame == expectedFrame)
    }

    @MainActor
    @Test func tableReturnOpensExactlyOnce() {
        let delegate = BookmarkMenuTableViewDelegateSpy()
        let table = BookmarkMenuTableView()
        table.menuDelegate = delegate
        table.keyDown(with: keyEvent(keyCode: UInt16(kVK_Return), characters: "\r"))
        table.keyDown(with: keyEvent(
            keyCode: UInt16(kVK_ANSI_KeypadEnter),
            characters: "\r",
            modifierFlags: .numericPad
        ))
        #expect(delegate.openSelectionCount == 2)
    }

    @MainActor
    @Test func archiveAndRestorePersistInNormalizedDatabase() async throws {
        try await withStore { store in
            let bookmark = try store.add(title: "Archive", url: "https://archive.example")
            let archivedAt = Date(timeIntervalSince1970: 123)
            try store.setArchived(true, ids: [bookmark.id], at: archivedAt)
            #expect(try store.snapshot().bookmarks.first?.archivedAt == archivedAt)
            try store.setArchived(false, ids: [bookmark.id])
            #expect(try store.snapshot().bookmarks.first?.archivedAt == nil)
        }
    }

    @MainActor
    @Test func manualArchiveRemainsEffectiveWhenAutoArchiveIsDisabled() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: BookmarksModel.autoArchiveEnabledKey)
        defer { restore(previous, key: BookmarksModel.autoArchiveEnabledKey, defaults: defaults) }
        defaults.set(false, forKey: BookmarksModel.autoArchiveEnabledKey)

        try await withStore { store in
            let bookmark = try store.add(title: "Manual Archive", url: "https://manual-archive.example")
            try store.setArchived(true, ids: [bookmark.id])
            let model = BookmarksModel(store: store)
            let archived = try #require(model.bookmarks.first)
            #expect(model.isEffectivelyArchived(archived))
            #expect(model.visibleUngroupedBookmarks.isEmpty)
            #expect(model.menuRenderSections().allSatisfy { section in
                !section.bookmarks.contains(where: { $0.id == bookmark.id })
            })
            #expect(model.setArchived(false, for: bookmark.id) == nil)
            #expect(model.visibleUngroupedBookmarks.contains(where: { $0.id == bookmark.id }))
        }
    }

    @MainActor
    @Test func batchDeleteRemovesOnlySelectedBookmarks() async throws {
        try await withStore { store in
            let first = try store.add(title: "First", url: "https://first.example")
            let second = try store.add(title: "Second", url: "https://second.example")
            let kept = try store.add(title: "Kept", url: "https://kept.example")
            try store.delete(ids: [first.id, second.id])
            #expect(try store.snapshot().bookmarks.map(\.id) == [kept.id])
        }
    }

    @MainActor
    @Test func titleOptimizationPersistsOriginalAndSupportsRevert() async throws {
        try await withStore { store in
            let original = "(14) Inbox | user@example.com | Proton Mail"
            let first = try store.add(title: original, url: "https://mail.proton.me/u/0/inbox")
            let second = try store.add(title: "Claude", url: "https://claude.ai/new")
            #expect(try store.applyTitleOptimizations([
                first.id: "Proton Mail",
                second.id: "Claude",
            ]) == 2)

            var bookmarks = try store.snapshot().bookmarks
            #expect(bookmarks.first(where: { $0.id == first.id })?.title == "Proton Mail")
            #expect(bookmarks.first(where: { $0.id == first.id })?.originalTitle == original)
            #expect(try store.applyTitleOptimizations([first.id: "Mail"]) == 0)
            #expect(try store.revertTitleOptimizations(ids: [first.id]) == 1)

            bookmarks = try store.snapshot().bookmarks
            #expect(bookmarks.first(where: { $0.id == first.id })?.title == original)
            #expect(bookmarks.first(where: { $0.id == first.id })?.titleOptimizationState == .notAttempted)
            #expect(try store.applyOriginalTitles([first.id: "Inbox - Proton Mail"], forceApplyDisplay: true) == 1)
            #expect(try store.snapshot().bookmarks.first(where: { $0.id == first.id })?.title == "Inbox - Proton Mail")
        }
    }

    @Test func titleOptimizationPreferencesRemainIndependent() throws {
        let suite = "ObeliskTitlePreferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visible = Bookmark(title: "Visible", url: "https://visible.example")
        let hidden = Bookmark(title: "Hidden", url: "https://hidden.example", isHidden: true)
        TitleOptimizationPreferences.register(in: defaults)

        #expect(TitleOptimizationPreferences.allowsOptimization(for: visible, defaults: defaults))
        #expect(!TitleOptimizationPreferences.allowsOptimization(for: hidden, defaults: defaults))
        #expect(!TitleOptimizationPreferences.allowsAutoOptimization(for: visible, defaults: defaults))
        defaults.set(true, forKey: TitleOptimizationPreferences.autoOptimizeNewBookmarksKey)
        #expect(TitleOptimizationPreferences.allowsAutoOptimization(for: visible, defaults: defaults))
        #expect(!TitleOptimizationPreferences.allowsAutoOptimization(for: hidden, defaults: defaults))
        defaults.set(true, forKey: TitleOptimizationPreferences.optimizeHiddenBookmarksKey)
        #expect(TitleOptimizationPreferences.allowsAutoOptimization(for: hidden, defaults: defaults))
    }

    @MainActor
    @Test func titleTranslationPromptUsesPreferenceLanguageWithoutForcingChinese() {
        let off = TitleOptimizer.systemPrompt(translateNonChineseTitles: false)
        #expect(off.contains("Prefer the user's language when obvious from the title or URL."))
        #expect(!off.contains("TRANSLATE_NON_CHINESE_TO_CHINESE"))
        let on = TitleOptimizer.systemPrompt(translateNonChineseTitles: true)
        #expect(on.contains("Translation preference:"))
        #expect(on.contains("when it is reasonable"))
        #expect(!on.contains("MUST contain natural Chinese"))
    }

    @Test func usageRankingFiltersAndOrdersDeterministically() {
        let frequent = Bookmark(title: "Frequent", url: "https://frequent.example", createdAt: Date(timeIntervalSince1970: 10))
        let low = Bookmark(title: "Low", url: "https://low.example", createdAt: Date(timeIntervalSince1970: 20))
        let stale = Bookmark(title: "Stale", url: "https://stale.example", createdAt: Date(timeIntervalSince1970: 30))
        let alpha = Bookmark(title: "Alpha", url: "https://alpha.example", createdAt: Date(timeIntervalSince1970: 40))
        let beta = Bookmark(title: "Beta", url: "https://beta.example", createdAt: Date(timeIntervalSince1970: 50))
        let undated = Bookmark(title: "Undated", url: "https://undated.example", createdAt: .distantPast)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let usage = [
            frequent.id: UsageRecord(count: 5, lastClickedAt: now),
            low.id: UsageRecord(count: 1, lastClickedAt: now),
            stale.id: UsageRecord(count: 2, lastClickedAt: now.addingTimeInterval(-60 * 86_400)),
        ]

        #expect(BookmarkUsageRanking.topFrequent(
            among: [frequent, low, stale],
            usage: usage,
            limit: 5,
            now: now
        ).map(\.id) == [frequent.id])
        #expect(BookmarkUsageRanking.recent(among: [frequent, low, undated], limit: 5).map(\.id) == [low.id, frequent.id])
        #expect(BookmarkUsageRanking.frecencySorted(
            among: [beta, stale, frequent, low, undated, alpha],
            usage: usage,
            now: now
        ).map(\.id) == [frequent.id, low.id, stale.id, alpha.id, beta.id, undated.id])
    }

    @MainActor
    @Test func titleOptimizationFiltersHiddenBookmarksByPreference() async throws {
        let defaults = UserDefaults.standard
        let ai = defaults.object(forKey: BookmarksModel.aiFeaturesEnabledKey)
        let hiddenPreference = defaults.object(forKey: TitleOptimizationPreferences.optimizeHiddenBookmarksKey)
        defer {
            restore(ai, key: BookmarksModel.aiFeaturesEnabledKey, defaults: defaults)
            restore(hiddenPreference, key: TitleOptimizationPreferences.optimizeHiddenBookmarksKey, defaults: defaults)
        }
        defaults.set(true, forKey: BookmarksModel.aiFeaturesEnabledKey)
        defaults.set(false, forKey: TitleOptimizationPreferences.optimizeHiddenBookmarksKey)

        try await withStore { store in
            let visible = try store.add(title: "Visible Raw", url: "https://visible-filter.example")
            let hidden = try store.add(title: "Hidden Raw", url: "https://hidden-filter.example", isHidden: true)
            let firstOptimizer = StubTitleOptimizer(response: [
                visible.id: "Visible Optimized",
                hidden.id: "Hidden Optimized",
            ])
            let firstModel = BookmarksModel(store: store, titleOptimizer: firstOptimizer)
            #expect(await firstModel.optimizeTitleDetails(bookmarkIds: [visible.id, hidden.id]).message == "已优化 1 个标题")
            #expect(firstOptimizer.candidateIDs == [visible.id])

            defaults.set(true, forKey: TitleOptimizationPreferences.optimizeHiddenBookmarksKey)
            let secondOptimizer = StubTitleOptimizer(response: [hidden.id: "Hidden Optimized"])
            let secondModel = BookmarksModel(store: store, titleOptimizer: secondOptimizer)
            #expect(await secondModel.optimizeTitleDetails(bookmarkIds: [hidden.id]).message == "已优化 1 个标题")
            #expect(secondOptimizer.candidateIDs == [hidden.id])
        }
    }

    @MainActor
    @Test func titleOptimizationOutcomeExposesUpdatedTitle() async throws {
        let defaults = UserDefaults.standard
        let ai = defaults.object(forKey: BookmarksModel.aiFeaturesEnabledKey)
        defer { restore(ai, key: BookmarksModel.aiFeaturesEnabledKey, defaults: defaults) }
        defaults.set(true, forKey: BookmarksModel.aiFeaturesEnabledKey)

        try await withStore { store in
            let bookmark = try store.add(title: "Raw", url: "https://outcome.example")
            let optimizer = StubTitleOptimizer(response: [bookmark.id: "Optimized"])
            let model = BookmarksModel(store: store, titleOptimizer: optimizer)
            let outcome = await model.optimizeTitleDetails(bookmarkIds: [bookmark.id])
            #expect(outcome.message == "已优化 1 个标题")
            #expect(outcome.optimizedTitles == ["Optimized"])
            #expect(await model.optimizeTitleDetails(bookmarkIds: [bookmark.id]).message == "没有需要优化的标题")
        }
    }

    @Test func freshDefaultsEnableOnlyExpectedWorkflows() throws {
        let suite = "com.eli.Obelisk.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ObeliskAppDefaults.register(in: defaults)
        #expect(defaults.bool(forKey: ObeliskAppDefaults.openHiddenBookmarksIncognitoKey))
        #expect(!defaults.bool(forKey: TitleOptimizationPreferences.optimizeHiddenBookmarksKey))
        #expect(HiddenBookmarkKeywordExclusion.keywords(in: defaults).isEmpty)
    }

    @MainActor
    @Test func sidebarResizeAndSelectionKeepRowsInsideViewport() throws {
        var selection: BookmarkManagerView.SettingsPage? = .bookmarks
        var scope = BookmarkManagerView.CollectionScope.recent
        var expanded = true
        let collections = (0..<5).map { BookmarkCollection(name: "Group \($0)", sortOrder: $0) }
        let sidebar = AppKitSettingsSidebar(
            pages: [.bookmarks, .collections],
            selectedPage: Binding(get: { selection }, set: { selection = $0 }),
            collections: collections,
            selectedCollectionScope: Binding(get: { scope }, set: { scope = $0 }),
            collectionsExpanded: Binding(get: { expanded }, set: { expanded = $0 }),
            badgeCount: { $0 == .bookmarks ? 176 : 5 },
            collectionScopeBadgeCount: { _ in 0 },
            onCreateCollection: {},
            onRenameCollection: { _ in },
            onDeleteCollection: { _ in },
            onReorderCollections: { _ in },
            iconTheme: .colorful,
            iconStyle: .lucide,
            colorfulIconSize: 22,
            colorfulSymbolSize: 11,
            colorfulCornerRadius: 6,
            professionalIconSize: 15
        )
        let coordinator = sidebar.makeCoordinator()
        let scrollView = coordinator.makeScrollView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scrollView
        let table = try #require(scrollView.documentView as? NSTableView)
        table.reloadData()

        for width: CGFloat in [180, 280, 150, 340, 180] {
            window.setContentSize(NSSize(width: width, height: 400))
            scrollView.layoutSubtreeIfNeeded()
            table.layoutSubtreeIfNeeded()
            let columnWidthBeforeSelection = table.tableColumns[0].width

            for selectedRow in [1, 0] {
                table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
                coordinator.reloadIfNeeded()
                scrollView.layoutSubtreeIfNeeded()
                table.layoutSubtreeIfNeeded()
                #expect(abs(table.tableColumns[0].width - columnWidthBeforeSelection) < 1)
                #expect(abs(table.frame.width - scrollView.contentView.bounds.width) < 1)

                let row = try #require(table.rowView(atRow: selectedRow, makeIfNecessary: true))
                let rowRect = row.convert(row.bounds, to: scrollView.contentView)
                #expect(rowRect.maxX <= scrollView.contentView.bounds.maxX + 1)
                let cell = try #require(table.view(atColumn: 0, row: selectedRow, makeIfNecessary: true))
                cell.layoutSubtreeIfNeeded()
                let badge = try #require(cell.subviews.compactMap { $0 as? NSTextField }
                    .first { $0.stringValue == (selectedRow == 0 ? "176" : "5") })
                #expect(abs(cell.bounds.maxX - badge.alignmentRect(forFrame: badge.frame).maxX - 14) < 1)
                let badgeRect = badge.convert(badge.bounds, to: scrollView.contentView)
                #expect(badgeRect.maxX <= scrollView.contentView.bounds.maxX)
                #expect(scrollView.contentView.bounds.maxX - badgeRect.maxX < 40)
            }
        }
    }

    @MainActor
    @Test func intelligenceSidebarUsesSharedSymbol() {
        #expect(IntelligenceSymbolIcon.symbolName == "siri")
        #expect(BookmarkManagerView.SettingsPage.ai.symbolName == IntelligenceSymbolIcon.symbolName)
    }

    @Test func cloudSyncSidebarAppearsAfterIntelligence() throws {
        let pages = BookmarkManagerView.SettingsPage.allCases
        let intelligenceIndex = try #require(pages.firstIndex(of: .ai))
        let cloudSyncIndex = try #require(pages.firstIndex(of: .cloudSync))

        #expect(cloudSyncIndex == intelligenceIndex + 1)
        #expect(BookmarkManagerView.SettingsPage.cloudSync.group == .advanced)
        #expect(BookmarkManagerView.SettingsPage.cloudSync.title == "云同步")
        #expect(BookmarkManagerView.SettingsPage.cloudSync.symbolName == "cloud.fill")
    }

    @Test func browserTabParsingAndPermissionMappingRemainExplicit() {
        #expect(BrowserCurrentTab.parseScriptOutput("https://example.com/path\nExample") == .success(
            BrowserTab(url: "https://example.com/path", title: "Example")
        ))
        #expect(BrowserCurrentTab.parseScriptOutput(BrowserCurrentTab.noWindowSentinel) == .failure(.noBrowserWindow))
        #expect(BrowserCurrentTab.parseScriptOutput("not-a-url\nBad") == .failure(.invalidURL))
        #expect(BrowserCurrentTab.result(forAppleScriptError: [
            "NSAppleScriptErrorNumber": NSNumber(value: -1743)
        ]) == .failure(.automationPermissionRequired))
        #expect(BrowserCurrentTab.result(forAppleScriptError: [
            "NSAppleScriptErrorNumber": NSNumber(value: -1728)
        ]) == .failure(.scriptFailed(-1728)))
    }

    @Test func hotkeyResolverFailsClosedWithoutConfirmedBrowserTab() {
        #expect(HotkeyBookmarkResolver.resolve(
            currentTab: .success(BrowserTab(url: "https://current.example", title: "Current"))
        ) == .resolved(url: "https://current.example", title: "Current"))
        #expect(HotkeyBookmarkResolver.resolve(
            currentTab: .failure(.automationPermissionRequired)
        ) == .failed(
            message: "请在“隐私与安全性 > 自动化”允许 Obelisk 控制当前浏览器",
            settingsDestination: .automation
        ))
        #expect(HotkeyBookmarkResolver.resolve(
            currentTab: .failure(.unsupportedFrontmostApplication("com.apple.finder"))
        ) == .failed(message: "请先切到要添加的浏览器标签页", settingsDestination: nil))
        #expect(HotkeyBookmarkResolver.resolve(
            currentTab: .failure(.invalidURL)
        ) == .failed(message: "当前浏览器标签无有效网址", settingsDestination: nil))
    }

    @Test func privateBrowserPermissionMappingRemainsExplicit() {
        #expect(PrivateBrowserOpener.result(forAppleScriptError: [
            "NSAppleScriptErrorNumber": NSNumber(value: -1743)
        ]) == .automationPermissionRequired(.appleEvents))
        #expect(PrivateBrowserOpener.result(forAppleScriptError: [
            "NSAppleScriptErrorNumber": NSNumber(value: -1728)
        ]) == .openFailed)
    }

    @Test func chromeUsesNativeIncognitoWindowAutomation() throws {
        #expect(PrivateBrowserOpener.strategy(forBundleID: "com.google.Chrome") == .chromeAppleScript)
        #expect(PrivateBrowserOpener.strategy(forBundleID: "com.microsoft.edgemac") == .chromiumLaunchArguments)
        #expect(PrivateBrowserOpener.strategy(forBundleID: "com.apple.Safari") == .unsupported)

        let source = PrivateBrowserOpener.chromeAppleScriptSource(
            url: try #require(URL(string: "https://example.com/obelisk-incognito-test")),
            bundleID: "com.google.Chrome",
            savedWindowID: "window-1"
        )
        #expect(source.contains("first window whose id is savedWindowID"))
        #expect(source.contains("make new tab at end of tabs with properties {URL:targetURL}"))
        #expect(source.contains("set active tab index to count of tabs"))
        #expect(source.contains("make new window with properties {mode:\"incognito\"}"))
        #expect(source.contains("set URL of active tab of privateWindow to targetURL"))
        #expect(source.contains("return (mode of privateWindow as text) & linefeed & (id of privateWindow as text)"))

        #expect(
            PrivateBrowserOpener.chromeIncognitoWindowID(
                fromAppleScriptOutput: "incognito\nwindow-1"
            ) == "window-1"
        )
        #expect(PrivateBrowserOpener.chromeIncognitoWindowID(fromAppleScriptOutput: "normal\nwindow-1") == nil)
        #expect(PrivateBrowserOpener.chromeIncognitoWindowID(fromAppleScriptOutput: "incognito\n") == nil)
    }

    @MainActor
    private func withStore(
        _ body: @MainActor (BookmarkStore) async throws -> Void
    ) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BookmarkStore.open(
            rootDirectory: root,
            deviceID: UUID()
        )
        try await body(store)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskFeatureTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

private final class InMemoryAccessKeyStore: SyncAccessKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    func load() throws -> String? {
        lock.withLock { key }
    }

    func save(_ key: String) throws {
        lock.withLock { self.key = key }
    }

    func clear() throws {
        lock.withLock { key = nil }
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


@MainActor
private final class HiddenBookmarksSidebarMenuActionStub: NSObject {
    @objc func toggle(_ sender: Any?) {}
}

@MainActor
private final class BookmarkMenuTableViewDelegateSpy: BookmarkMenuTableViewDelegate {
    private(set) var openSelectionCount = 0

    func bookmarkMenuTableView(_ tableView: BookmarkMenuTableView, shouldSelectContextRow row: Int) -> Bool { false }
    func bookmarkMenuTableView(_ tableView: BookmarkMenuTableView, menuForRow row: Int) -> NSMenu? { nil }
    func bookmarkMenuTableViewCopySelection(_ tableView: BookmarkMenuTableView) {}
    func bookmarkMenuTableViewEditSelection(_ tableView: BookmarkMenuTableView) {}
    func bookmarkMenuTableViewDeleteSelection(_ tableView: BookmarkMenuTableView) {}
    func bookmarkMenuTableViewOpenSelection(_ tableView: BookmarkMenuTableView) { openSelectionCount += 1 }
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
