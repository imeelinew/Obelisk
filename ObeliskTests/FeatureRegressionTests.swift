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
    @Test func cloudSyncStartsLocallyWithoutAnAccount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObeliskCloudSync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ObeliskCloudSyncDefaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let database = try await ObeliskDatabase.open(
            rootDirectory: root,
            deviceID: UUID()
        )
        let sessionStore = RecordingCloudSessionStore()
        let auth = ObeliskAuthClient(
            configuration: ObeliskServerConfiguration(
                apiURL: URL(string: "https://api.example.test")!,
                powerSyncURL: URL(string: "https://sync.example.test")!
            ),
            store: sessionStore
        )
        let controller = CloudSyncController(
            database: database,
            authClient: auth,
            defaults: defaults
        )

        await controller.start()
        #expect(!controller.isEnabled)
        #expect(!controller.isAuthenticated)
        #expect(controller.phase == .off)
        #expect(sessionStore.loadCount == 0)

        await controller.setEnabled(true)
        #expect(controller.phase == .authenticationRequired)
        #expect(sessionStore.loadCount == 1)

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

    @Test func duplicateListRowsKeepIndependentSelectionKeys() {
        let bookmark = Bookmark(title: "Duplicate", url: "https://duplicate.example")
        let items = [
            BookmarkListSection(
                title: "最近添加 (1)",
                bookmarks: [bookmark],
                referenceIndicatorSystemImage: FaviconReferenceBadge.systemImageName
            ),
            BookmarkListSection(title: "未分组 (1)", bookmarks: [bookmark]),
        ].flattenedItems

        #expect(items.count == 4)
        #expect(items[1].isReference)
        #expect(!items[3].isReference)
        let reference = NativeBookmarkSelectionResolver.selection(
            from: IndexSet(integer: 1),
            in: items,
            allowsCollectionSelection: false
        )
        #expect(NativeBookmarkSelectionResolver.rowIndexes(
            for: reference.bookmarkIDs,
            selectedRowKeys: reference.rowKeys,
            selectedCollectionId: nil,
            in: items
        ) == IndexSet(integer: 1))
        #expect(NativeBookmarkSelectionResolver.rowIndexes(
            for: [bookmark.id],
            selectedRowKeys: [],
            selectedCollectionId: nil,
            in: items
        ) == IndexSet(integer: 3))
    }

    @Test func duplicateListRowsResolveToUniqueOperationTargets() {
        let first = Bookmark(title: "First", url: "https://first.example")
        let second = Bookmark(title: "Second", url: "https://second.example")

        let targets = BookmarkOperationTargetResolver.bookmarks(
            in: [first, first, second],
            matching: [first.id, second.id]
        )

        #expect(targets.map(\.id) == [first.id, second.id])
    }

    @Test func firstBookmarkSelectionSkipsSectionHeaders() {
        let bookmark = Bookmark(title: "YouTube", url: "https://youtube.com")
        #expect(NativeBookmarkSelectionResolver.firstBookmarkRowIndex(in: [
            BookmarkListSection(title: "置顶 (1)", bookmarks: [bookmark])
        ].flattenedItems) == 1)
        #expect(NativeBookmarkSelectionResolver.firstBookmarkRowIndex(in: [
            BookmarkListSection(title: "没有结果", bookmarks: [])
        ].flattenedItems) == nil)
    }

    @MainActor
    @Test func nativeCardGridKeepsAdaptiveCardWidthsWithinItsVisualContract() {
        #expect(!BookmarkCardFlowLayout.isUsableCollectionWidth(100))
        #expect(BookmarkCardFlowLayout.isUsableCollectionWidth(880))
        #expect(BookmarkCardFlowLayout.itemWidth(for: 880) == 202)
        #expect(BookmarkCardFlowLayout.itemWidth(for: 520) == 224)
        #expect(BookmarkCardFlowLayout.itemWidth(for: 180) == 144)
    }

    @MainActor
    @Test func nativeCardsRenderTheirMaterialWithTheOriginalSwiftUIBackground() {
        let materialView = BookmarkCardMaterialRenderer.makeView()
        #expect(materialView is NSHostingView<BookmarkCardMaterialBackground>)
        #expect(!(materialView is NSVisualEffectView))
    }

    @Test func bookmarkViewsShareOneKeyboardCommandResolver() {
        #expect(BookmarkKeyboardCommandResolver.resolve(
            characters: "c",
            keyCode: UInt16(kVK_ANSI_C),
            modifiers: .command
        ) == .copy)
        #expect(BookmarkKeyboardCommandResolver.resolve(
            characters: "e",
            keyCode: UInt16(kVK_ANSI_E),
            modifiers: .command
        ) == .edit)
        #expect(BookmarkKeyboardCommandResolver.resolve(
            characters: "",
            keyCode: UInt16(kVK_Escape),
            modifiers: []
        ) == .cancel)
        #expect(BookmarkKeyboardCommandResolver.resolve(
            characters: "",
            keyCode: UInt16(kVK_Tab),
            modifiers: []
        ) == .advanceSelection)
        #expect(BookmarkKeyboardCommandResolver.resolve(
            characters: "",
            keyCode: UInt16(kVK_Delete),
            modifiers: []
        ) == .delete)
        #expect(BookmarkKeyboardCommandResolver.resolve(
            characters: "",
            keyCode: UInt16(kVK_Return),
            modifiers: []
        ) == .open)
    }

    @Test func quickSearchShortcutTogglesTheVisiblePanel() {
        #expect(QuickSearchPanelToggleAction.resolve(isVisible: false) == .show)
        #expect(QuickSearchPanelToggleAction.resolve(isVisible: true) == .hide)
    }

    @Test func bookmarkFeedbackUsesDistinctTransientStates() {
        let kinds: [BookmarkFeedbackKind] = [.success, .hidden, .intelligence, .error]
        #expect(kinds.allSatisfy { $0.dismissalDelay == 5 })
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
        var copied = false
        var edited = false
        var reverted = false
        var pinned = false
        var assignedCollectionID: UUID?
        var hidden = false
        var archived = false
        var deleted = false
        var configuration = NativeBookmarkContextMenuConfiguration()
        configuration.onOpen = { opened = true }
        configuration.onCopyURL = { copied = true }
        configuration.onEdit = { edited = true }
        configuration.onRevertTitleOptimization = { reverted = true }
        configuration.pinStateActionTitle = "置顶".obeliskLocalized
        configuration.pinStateSystemSymbolName = "pin"
        configuration.onSetPinned = { pinned = true }
        configuration.collectionAssignOptions = [
            BookmarkCollectionAssignOption(title: "工作", collectionId: collectionID)
        ]
        configuration.onAssignCollection = { assignedCollectionID = $0 }
        configuration.hiddenStateActionTitle = "移到隐藏书签".obeliskLocalized
        configuration.hiddenStateSystemSymbolName = "eye.slash"
        configuration.onSetHidden = { hidden = true }
        configuration.archiveStateActionTitle = "归档".obeliskLocalized
        configuration.archiveStateSystemSymbolName = "archivebox"
        configuration.onSetArchived = { archived = true }
        configuration.onDelete = { deleted = true }

        let controller = NativeBookmarkContextMenuController()
        let menu = try #require(controller.makeMenu(configuration: configuration))

        #expect(menu.items.map(\.isSeparatorItem) == [
            false, false, false, false,
            true, false,
            true, false,
            true, false,
            true, false,
            true, false
        ])
        #expect(menu.items[0].title == "打开".obeliskLocalized)
        #expect(menu.items[0].image != nil)
        #expect(menu.items[7].title == "移到分组".obeliskLocalized)
        #expect(menu.items[7].submenu?.items.map(\.title) == ["工作"])
        #expect(menu.items[13].title == "删除".obeliskLocalized)
        let destructiveTitle = try #require(menu.items[13].attributedTitle)
        #expect(destructiveTitle.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor == .systemRed)

        menu.delegate?.menuDidClose?(menu)
        menu.performActionForItem(at: 0)
        menu.performActionForItem(at: 1)
        menu.performActionForItem(at: 2)
        menu.performActionForItem(at: 3)
        menu.performActionForItem(at: 5)
        menu.items[7].submenu?.performActionForItem(at: 0)
        menu.performActionForItem(at: 9)
        menu.performActionForItem(at: 11)
        menu.performActionForItem(at: 13)
        #expect(opened)
        #expect(copied)
        #expect(edited)
        #expect(reverted)
        #expect(pinned)
        #expect(assignedCollectionID == collectionID)
        #expect(hidden)
        #expect(archived)
        #expect(deleted)
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

    @Test func bookmarkFeedbackHUDUsesTheCurrentScreensUpperCenter() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1_400, height: 900)
        let frame = BookmarkFeedbackPanelLayout.anchorFrame(in: visibleFrame)

        #expect(frame.midX == visibleFrame.midX)
        #expect(frame.maxY == visibleFrame.maxY - BookmarkFeedbackPanelLayout.topInset)
        #expect(frame.size == BookmarkFeedbackPanelLayout.anchorSize)
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

    @Test func quickSearchPanelAlignmentSnapsEachAxisIndependently() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1_400, height: 900)
        let centeredOrigin = NSPoint(x: 600, y: 250)
        let frame = NSRect(
            x: centeredOrigin.x + 6,
            y: centeredOrigin.y + 30,
            width: 400,
            height: 500
        )

        let resolution = QuickSearchPanelAlignmentResolver.resolve(
            frame: frame,
            visibleFrame: visibleFrame,
            alignsHorizontally: true,
            alignsVertically: false
        )

        #expect(resolution.frame.origin.x == centeredOrigin.x)
        #expect(resolution.frame.origin.y == frame.origin.y)
    }

    @Test func quickSearchPanelAlignmentLeavesFrameAloneWithoutNativeTokens() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_400, height: 900)
        let frame = NSRect(x: 506, y: 217, width: 400, height: 500)

        let resolution = QuickSearchPanelAlignmentResolver.resolve(
            frame: frame,
            visibleFrame: visibleFrame,
            alignsHorizontally: false,
            alignsVertically: false
        )

        #expect(resolution.frame == frame)
    }

    @Test func quickSearchPanelAlignmentAmplifiesNativeCaptureRange() {
        let guide: CGFloat = 700
        let actualCoordinate: CGFloat = 720
        let feedbackCoordinate = QuickSearchPanelAlignmentResolver.feedbackCoordinate(
            default: actualCoordinate,
            alignedTo: guide
        )

        #expect(feedbackCoordinate == 714)
        #expect(abs(feedbackCoordinate - guide) < abs(actualCoordinate - guide))
    }

    @MainActor
    @Test func quickSearchPanelDragStartsOnlyFromNoninteractiveBackground() {
        let rootView = NSView()
        let backgroundView = NSView()
        let searchField = NSSearchField()
        let scrollView = NSScrollView()
        let tableView = NSTableView()
        let button = NSButton()
        rootView.addSubview(backgroundView)
        rootView.addSubview(searchField)
        rootView.addSubview(scrollView)
        rootView.addSubview(button)
        scrollView.documentView = tableView

        #expect(QuickSearchPanelDragTargetResolver.allowsWindowDrag(
            from: backgroundView,
            within: rootView
        ))
        #expect(!QuickSearchPanelDragTargetResolver.allowsWindowDrag(
            from: searchField,
            within: rootView
        ))
        #expect(!QuickSearchPanelDragTargetResolver.allowsWindowDrag(
            from: tableView,
            within: rootView
        ))
        #expect(!QuickSearchPanelDragTargetResolver.allowsWindowDrag(
            from: button,
            within: rootView
        ))
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
    @Test func browserHistoryReturnOpensSelectedRecord() throws {
        let record = BrowserHistoryRecord(
            id: UUID(),
            title: "Safari history",
            url: "https://history.example",
            visitedAt: Date(),
            browser: .safari,
            profileName: "Safari"
        )
        var opened: UUID?
        let list = NativeBrowserHistoryList(
            sections: [BrowserHistorySection(id: "today", title: "今天", records: [record])],
            selection: .constant([]),
            faviconLoader: FaviconLoader(rootDirectory: try temporaryDirectory()),
            faviconVersion: 0,
            onOpen: { opened = $0.id }
        )
        let coordinator = NativeBrowserHistoryList.Coordinator(list)
        let table = BookmarkMenuTableView()
        table.dataSource = coordinator
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("test")))
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        coordinator.bookmarkMenuTableViewOpenSelection(table)
        #expect(opened == record.id)
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
            #expect(model.visibleUngroupedSections(sortMode: .name).isEmpty)
            #expect(model.menuRenderSections().allSatisfy { section in
                !section.bookmarks.contains(where: { $0.id == bookmark.id })
            })
            #expect(model.setArchived(false, for: bookmark.id) == nil)
            #expect(model.visibleUngroupedSections(sortMode: .name)
                .flatMap(\.bookmarks)
                .contains(where: { $0.id == bookmark.id }))
        }
    }

    @MainActor
    @Test func pinnedBookmarksLeadLibraryAndLeaveOtherSections() async throws {
        try await withStore { store in
            let pinned = try store.add(title: "Pinned", url: "https://pinned.example")
            let plain = try store.add(title: "Plain", url: "https://plain.example")
            try store.setPinned(true, ids: [pinned.id])
            let model = BookmarksModel(store: store)
            let sections = model.bookmarkLibrarySections(
                for: model.bookmarks,
                pinnedSortMode: .name,
                collectionSortMode: .name,
                ungroupedSortMode: .name
            )
            #expect(sections.first?.title == "置顶 (1)")
            #expect(sections.first?.bookmarks.map(\.id) == [pinned.id])
            #expect(sections.first(where: { $0.title == "未分组 (1)" })?.bookmarks.map(\.id) == [plain.id])
        }
    }

    @MainActor
    @Test func hiddenArchivedAndDeletedBookmarksCannotRemainPinned() async throws {
        try await withStore { store in
            var hidden = try store.add(title: "Hide", url: "https://hide.example")
            let archived = try store.add(title: "Archive", url: "https://archive-pinned.example")
            try store.setPinned(true, ids: [hidden.id, archived.id])
            hidden.isHidden = true
            _ = try store.update(hidden)
            try store.setArchived(true, ids: [archived.id])

            var snapshot = try store.snapshot()
            #expect(snapshot.bookmarks.first(where: { $0.id == hidden.id })?.isPinned == false)
            #expect(snapshot.bookmarks.first(where: { $0.id == archived.id })?.isPinned == false)

            try store.delete(ids: [hidden.id, archived.id])
            snapshot = try store.snapshot()
            #expect(snapshot.bookmarks.isEmpty)
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
            #expect(bookmarks.first(where: { $0.id == first.id })?.titleOptimized == false)
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
            #expect(await firstModel.optimizeTitles(bookmarkIds: [visible.id, hidden.id]) == "已优化 1 个标题")
            #expect(firstOptimizer.candidateIDs == [visible.id])

            defaults.set(true, forKey: TitleOptimizationPreferences.optimizeHiddenBookmarksKey)
            let secondOptimizer = StubTitleOptimizer(response: [hidden.id: "Hidden Optimized"])
            let secondModel = BookmarksModel(store: store, titleOptimizer: secondOptimizer)
            #expect(await secondModel.optimizeTitles(bookmarkIds: [hidden.id]) == "已优化 1 个标题")
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
            #expect(await model.optimizeTitles(bookmarkIds: [bookmark.id]) == "没有需要优化的标题")
        }
    }

    @Test func automaticIntelligenceOptionsRemainIndependent() {
        let defaults = UserDefaults.standard
        let title = defaults.object(forKey: TitleOptimizationPreferences.autoOptimizeNewBookmarksKey)
        let grouping = defaults.object(forKey: BookmarkAutoGroupingPreferences.autoGroupNewBookmarksKey)
        defer {
            restore(title, key: TitleOptimizationPreferences.autoOptimizeNewBookmarksKey, defaults: defaults)
            restore(grouping, key: BookmarkAutoGroupingPreferences.autoGroupNewBookmarksKey, defaults: defaults)
        }
        let bookmark = Bookmark(title: "Visible", url: "https://visible.example")
        for optimizeTitles in [false, true] {
            for autoGroup in [false, true] {
                defaults.set(optimizeTitles, forKey: TitleOptimizationPreferences.autoOptimizeNewBookmarksKey)
                defaults.set(autoGroup, forKey: BookmarkAutoGroupingPreferences.autoGroupNewBookmarksKey)
                #expect(BookmarkIntelligenceOptimizationOptions.automatic(
                    for: bookmark,
                    defaults: defaults
                ) == BookmarkIntelligenceOptimizationOptions(
                    optimizeTitles: optimizeTitles,
                    autoGroup: autoGroup
                ))
            }
        }
    }

    @MainActor
    @Test func combinedIntelligenceGroupsUsingOptimizedTitles() async throws {
        let defaults = UserDefaults.standard
        let ai = defaults.object(forKey: BookmarksModel.aiFeaturesEnabledKey)
        defer { restore(ai, key: BookmarksModel.aiFeaturesEnabledKey, defaults: defaults) }
        defaults.set(true, forKey: BookmarksModel.aiFeaturesEnabledKey)

        try await withStore { store in
            let first = try store.add(title: "First Original", url: "https://first.example")
            let second = try store.add(title: "Second Original", url: "https://second.example")
            let titleOptimizer = StubTitleOptimizer(response: [
                first.id: "First Optimized",
                second.id: "Second Optimized",
            ])
            let groupOptimizer = StubBookmarkGroupOptimizer(response: [
                first.id: "开发",
                second.id: "开发",
            ])
            let model = BookmarksModel(
                store: store,
                titleOptimizer: titleOptimizer,
                groupOptimizer: groupOptimizer
            )
            #expect(model.createCollection(name: "开发") == nil)
            let outcome = await model.optimizeBookmarks(options: .init(optimizeTitles: true, autoGroup: true))
            #expect(Set(titleOptimizer.candidateIDs) == [first.id, second.id])
            #expect(Set(groupOptimizer.candidateTitles) == ["First Optimized", "Second Optimized"])
            #expect(outcome.didChange)
            #expect(outcome.summary == "优化标题 2 个；自动分组 2 个")
        }
    }

    @Test func intelligenceOutcomeSummaryPreservesPartialFailures() {
        let partial = BookmarkIntelligenceOptimizationOutcome(
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
        #expect(partial.didChange)
        #expect(partial.summary == "标题「Optimized」；分组请求失败")
        let unchanged = BookmarkIntelligenceOptimizationOutcome(
            titleOptimization: TitleOptimizationOutcome(message: "没有需要优化的标题", optimizedTitles: []),
            autoGrouping: BookmarkAutoGroupingOutcome(
                message: "没有需要自动分组的书签",
                groupedCount: 0,
                placements: []
            )
        )
        #expect(!unchanged.didChange)
        #expect(unchanged.summary == "没有需要优化的标题；没有需要自动分组的书签")
    }

    @MainActor
    @Test func autoGroupingUsesOnlyExistingCollections() async throws {
        let defaults = UserDefaults.standard
        let ai = defaults.object(forKey: BookmarksModel.aiFeaturesEnabledKey)
        defer { restore(ai, key: BookmarksModel.aiFeaturesEnabledKey, defaults: defaults) }
        defaults.set(true, forKey: BookmarksModel.aiFeaturesEnabledKey)

        try await withStore { store in
            let docs = try store.add(title: "Swift Concurrency", url: "https://developer.apple.com/swift")
            let recipe = try store.add(title: "Sourdough", url: "https://example.com/sourdough")
            let groupOptimizer = StubBookmarkGroupOptimizer(response: [docs.id: "开发", recipe.id: "食谱"])
            let model = BookmarksModel(store: store, groupOptimizer: groupOptimizer)
            #expect(model.createCollection(name: "开发") == nil)
            let outcome = await model.autoGroupBookmarks()
            #expect(outcome.groupedCount == 1)
            #expect(groupOptimizer.existingCollectionNames == ["开发"])
            #expect(model.collectionId(for: docs.id) != nil)
            #expect(model.collectionId(for: recipe.id) == nil)
            #expect(!model.collections.contains(where: { $0.name == "食谱" }))
        }
    }

    @MainActor
    @Test func autoGroupingSkipsGroupedPinnedAndHiddenBookmarks() async throws {
        let defaults = UserDefaults.standard
        let ai = defaults.object(forKey: BookmarksModel.aiFeaturesEnabledKey)
        defer { restore(ai, key: BookmarksModel.aiFeaturesEnabledKey, defaults: defaults) }
        defaults.set(true, forKey: BookmarksModel.aiFeaturesEnabledKey)

        try await withStore { store in
            let grouped = try store.add(title: "Grouped", url: "https://grouped.example")
            let pinned = try store.add(title: "Pinned", url: "https://pinned.example")
            let hidden = try store.add(title: "Hidden", url: "https://hidden.example", isHidden: true)
            let ungrouped = try store.add(title: "Ungrouped", url: "https://ungrouped.example")
            try store.setPinned(true, ids: [pinned.id])
            let optimizer = StubBookmarkGroupOptimizer(response: [ungrouped.id: "阅读"])
            let model = BookmarksModel(store: store, groupOptimizer: optimizer)
            #expect(model.createCollection(name: "工作") == nil)
            #expect(model.createCollection(name: "阅读") == nil)
            let work = try #require(model.collections.first(where: { $0.name == "工作" }))
            #expect(model.setBookmarkCollection(bookmarkId: grouped.id, collectionId: work.id) == nil)

            let outcome = await model.autoGroupBookmarks()
            #expect(outcome.groupedCount == 1)
            #expect(outcome.singleBookmarkDescription == "已归入「阅读」")
            #expect(optimizer.candidateIDs == [ungrouped.id])
            #expect(model.collectionId(for: grouped.id) == work.id)
            #expect(model.collectionId(for: pinned.id) == nil)
            #expect(model.collectionId(for: hidden.id) == nil)
            #expect(model.collectionId(for: ungrouped.id) != nil)
        }
    }

    @Test func freshDefaultsEnableOnlyExpectedWorkflows() throws {
        let suite = "com.eli.Obelisk.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ObeliskAppDefaults.register(in: defaults)
        #expect(defaults.bool(forKey: ObeliskAppDefaults.openHiddenBookmarksIncognitoKey))
        #expect(!defaults.bool(forKey: TitleOptimizationPreferences.optimizeHiddenBookmarksKey))
        #expect(!defaults.bool(forKey: BookmarkAutoGroupingPreferences.autoGroupNewBookmarksKey))
        #expect(HiddenBookmarkKeywordExclusion.keywords(in: defaults).isEmpty)
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

    @MainActor
    private func withStore(
        _ body: @MainActor (BookmarkStore) async throws -> Void
    ) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await BookmarkStore.open(
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

private final class RecordingCloudSessionStore: ObeliskSessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: ObeliskAuthSession?
    private var loads = 0

    var loadCount: Int {
        lock.withLock { loads }
    }

    func load() throws -> ObeliskAuthSession? {
        lock.withLock {
            loads += 1
            return session
        }
    }

    func save(_ session: ObeliskAuthSession) throws {
        lock.withLock { self.session = session }
    }

    func clear() throws {
        lock.withLock { session = nil }
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
