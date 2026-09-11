import AppKit
import Carbon.HIToolbox
import ObeliskCore
import ObeliskSync
import SwiftUI
import UniformTypeIdentifiers

enum BookmarkDisplayMode: String, CaseIterable, Identifiable {
    case list
    case dateGrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "列表".obeliskLocalized
        case .dateGrid: return "卡片".obeliskLocalized
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .dateGrid: return "square.grid.2x2"
        }
    }
}

struct BookmarkManagerView: View {
    @Environment(\.colorScheme) var colorScheme
    @Bindable var model: BookmarksModel
    @Bindable var cloudSync: CloudSyncController
    let faviconLoader: FaviconLoader
    let addRequest: AddBookmarkRequest
    @State var selection: Set<Bookmark.ID> = []
    @State var presentation: Presentation?
    @State var deleteConfirmation: DeleteConfirmation?
    @State var contextMenuConfirmation: ContextMenuConfirmation?
    @State var toast: Toast?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State var settingsPage: SettingsPage = .bookmarks
    @State var selectedCollectionId: UUID?
    @State var searchText = ""
    @State var searchFilter: SearchFilter = .all
    @State var searchFocusRequest = 0
    @State var intelligenceSettings = IntelligenceSettingsModel()
    @State var hiddenBookmarksUnlocked = false
    @State var quickLookController = QuickLookController()
    @AppStorage(SidebarIconTheme.storageKey) var sidebarIconThemeRaw = SidebarIconTheme.professional.rawValue
    @AppStorage(SidebarIconStyle.storageKey) var sidebarIconStyleRaw = SidebarIconStyle.tabler.rawValue
    @AppStorage(MenuBarIconStyle.storageKey) var menuBarIconStyleRaw = MenuBarIconStyle.outline.rawValue
    let sidebarIconTileSize = 22.0
    let sidebarIconSymbolSize = 11.0
    let sidebarIconCornerRadius = 6.0
    let professionalSidebarIconSize = 15.0
    @AppStorage("showHiddenBookmarksPage") var showHiddenBookmarksPage = false
    @AppStorage("showsURLHostOnly") var showsURLHostOnly = false
    @AppStorage("menuRecentGroupLimit") var menuRecentGroupLimit = 5
    @AppStorage(BookmarksModel.autoArchiveEnabledKey) var autoArchiveEnabled = false
    @AppStorage(BookmarksModel.archiveAfterDaysKey) var archiveAfterDays = BookmarksModel.defaultArchiveAfterDays
    @AppStorage("windowTransparencyEnabled") var windowTransparencyEnabled = false
    @AppStorage(ObeliskAppDefaults.openHiddenBookmarksIncognitoKey) var openHiddenBookmarksIncognito = true
    @AppStorage(HiddenBookmarkKeywordExclusion.storageKey) var hiddenBookmarkExcludedURLKeywordsRaw = ""
    @AppStorage(TitleOptimizationPreferences.optimizeHiddenBookmarksKey) var optimizeHiddenBookmarks = false
    @AppStorage(BookmarksModel.aiFeaturesEnabledKey) var aiFeaturesEnabled = true
    @AppStorage(BookmarkListSortMode.bookmarksStorageKey) var bookmarkListSortModeRaw = BookmarkListSortMode.name.rawValue
    @AppStorage(BookmarkListSortMode.pinnedStorageKey) var pinnedBookmarkListSortModeRaw = BookmarkListSortMode.name.rawValue
    @AppStorage(BookmarkListSortMode.collectionsStorageKey) var collectionListSortModeRaw = BookmarkListSortMode.name.rawValue
    @AppStorage(BookmarkListSortMode.hiddenStorageKey) var hiddenBookmarkListSortModeRaw = BookmarkListSortMode.name.rawValue
    @AppStorage("bookmarkDisplayMode") var bookmarkDisplayModeRaw = BookmarkDisplayMode.list.rawValue
    @AppStorage("hiddenBookmarkDisplayMode") var hiddenBookmarkDisplayModeRaw = BookmarkDisplayMode.list.rawValue
    @AppStorage("collectionBookmarkDisplayMode") var collectionBookmarkDisplayModeRaw = BookmarkDisplayMode.list.rawValue
    @AppStorage(BookmarkMenuSectionOrder.storageKey) var menuBarSectionOrderRaw = ""
    // 0 = 完全不透明（默认毛玻璃材质满强度）；上限 0.5（再透可读性会崩）。
    @AppStorage("windowSeeThrough") var windowSeeThrough: Double = 0.0
    @AppStorage("customTransparencyEnabled") var customTransparencyEnabled = false
    @State var showCustomTransparencyAlert = false
    @State var showNewCollectionDialog = false
    @State var newCollectionName = ""
    @State var collectionToRename: BookmarkCollection?
    @State var renameCollectionName = ""
    @State var collectionToDelete: BookmarkCollection?
    @State var newHiddenBookmarkExcludedURLKeyword = ""
    @State var pendingAutoIntelligenceTask: Task<Void, Never>?
    @State var draggingMenuBarSectionID: BookmarkMenuSectionID?
    @State var menuBarDragStartIndex: Int?
    @State var menuBarDragTargetIndex: Int?
    @State var menuBarDragOffsetY: CGFloat = 0
    let menuBarOrderRowHeight: CGFloat = 50
    var menuBarOrderBackgroundColor: Color {
        switch colorScheme {
        case .dark:
            return Color(red: 39 / 255, green: 41 / 255, blue: 54 / 255)
        default:
            return Color(red: 247 / 255, green: 247 / 255, blue: 247 / 255)
        }
    }

    var menuBarOrderTransparentBackgroundColor: Color {
        switch colorScheme {
        case .dark:
            return Color.white.opacity(0.04)
        default:
            return Color.black.opacity(0.04)
        }
    }

    var effectiveBlurAlpha: Double {
        guard windowTransparencyEnabled else { return 1.0 }
        return 1.0 - min(0.5, max(0.0, windowSeeThrough))
    }

    struct Toast: Equatable, Identifiable {
        enum Kind: Equatable {
            case success
            case error
        }

        let id = UUID()
        let message: String
        let kind: Kind

        var systemImage: String {
            switch kind {
            case .success: return "checkmark.circle.fill"
            case .error: return "xmark.circle.fill"
            }
        }

        var foregroundStyle: Color {
            switch kind {
            case .success: return .primary
            case .error: return Color(red: 0.82, green: 0.18, blue: 0.18)
            }
        }
    }

    enum Presentation: Identifiable {
        // `seq` is part of identity so re-issuing an add request with new
        // prefill while a stale sheet is somehow alive forces a fresh sheet.
        case add(seq: Int, prefilledURL: String?, prefilledTitle: String?, prefilledIsHidden: Bool)
        case edit(Bookmark)

        var id: String {
            switch self {
            case .add(let seq, _, _, _): return "add-\(seq)"
            case .edit(let bookmark): return "edit-\(bookmark.id.uuidString)"
            }
        }
    }

    enum SearchFilter: Hashable {
        case all
        case collection(UUID)
    }

    enum SettingsPage: String, CaseIterable, Hashable, Identifiable {
        case bookmarks
        case collections
        case search
        case hiddenBookmarks
        case archive
        case appearance
        case menuBar
        case shortcuts
        case ai
        case cloudSync
        case privacy
        case settings

        var id: String { rawValue }

        enum Group: String, CaseIterable, Identifiable {
            case content
            case preferences
            case advanced

            var id: String { rawValue }

            var title: String {
                switch self {
                case .content: return "内容".obeliskLocalized
                case .preferences: return "偏好".obeliskLocalized
                case .advanced: return "高级".obeliskLocalized
                }
            }
        }

        var group: Group {
            switch self {
            case .bookmarks, .collections, .search, .hiddenBookmarks, .archive: return .content
            case .appearance, .menuBar, .shortcuts:     return .preferences
            case .ai, .cloudSync, .privacy, .settings:  return .advanced
            }
        }

        var title: String {
            switch self {
            case .bookmarks:       return "书签".obeliskLocalized
            case .search:          return "搜索".obeliskLocalized
            case .collections:     return "分组".obeliskLocalized
            case .hiddenBookmarks: return "隐藏书签".obeliskLocalized
            case .archive:         return "归档".obeliskLocalized
            case .appearance:      return "外观".obeliskLocalized
            case .menuBar:         return "菜单栏".obeliskLocalized
            case .shortcuts:       return "快捷键".obeliskLocalized
            case .ai:              return "Intelligence"
            case .cloudSync:       return "云同步".obeliskLocalized
            case .privacy:         return "隐私".obeliskLocalized
            case .settings:        return "设置".obeliskLocalized
            }
        }

        /// SF Symbol used when the SVG sidebar resource is unavailable.
        var symbolName: String {
            switch self {
            case .bookmarks:       return "bookmark.fill"
            case .search:          return "magnifyingglass"
            case .collections:     return "folder.fill"
            case .hiddenBookmarks: return "eye.slash.fill"
            case .archive:         return "archivebox.fill"
            case .appearance:      return "paintpalette.fill"
            case .menuBar:         return "menubar.rectangle"
            case .shortcuts:       return "command"
            case .ai:              return IntelligenceSymbolIcon.symbolName
            case .cloudSync:       return "cloud.fill"
            case .privacy:         return "lock.fill"
            case .settings:        return "gearshape.fill"
            }
        }

        var professionalIconResourceName: String {
            switch self {
            case .bookmarks:       return "bookmark"
            case .search:          return "search"
            case .collections:     return "folder-bookmark"
            case .hiddenBookmarks: return "eye-off"
            case .archive:         return "archive"
            case .appearance:      return "palette"
            case .menuBar:         return "app-window"
            case .shortcuts:       return "command"
            case .ai:              return "astroid"
            case .cloudSync:       return "cloud"
            case .privacy:         return "hat-glasses"
            case .settings:        return "settings"
            }
        }

    }

    enum SearchFocusRequestResolver {
        static func resolve(current: Int, selectedPage: SettingsPage) -> Int {
            selectedPage == .search ? current &+ 1 : current
        }
    }

    struct DeleteConfirmation: Identifiable {
        let ids: Set<Bookmark.ID>

        var id: String {
            ids.map(\.uuidString).sorted().joined(separator: ",")
        }

        var count: Int {
            ids.count
        }
    }

    struct ContextMenuConfirmation: Identifiable {
        enum Kind {
            case pin(isPinned: Bool)
            case hide(isHidden: Bool)
            case archive(isArchived: Bool)
            case assign(collectionId: UUID?, collectionName: String?)
        }

        let ids: Set<Bookmark.ID>
        let kind: Kind

        var id: String {
            let idsKey = ids.map(\.uuidString).sorted().joined(separator: ",")
            switch kind {
            case .pin(let isPinned):
                return "pin-\(isPinned)-\(idsKey)"
            case .hide(let isHidden):
                return "hide-\(isHidden)-\(idsKey)"
            case .archive(let isArchived):
                return "archive-\(isArchived)-\(idsKey)"
            case .assign(let collectionId, _):
                return "assign-\(collectionId?.uuidString ?? "nil")-\(idsKey)"
            }
        }

        var count: Int { ids.count }

        var title: String {
            switch kind {
            case .pin(let isPinned):
                return (isPinned ? "置顶书签?" : "取消置顶?").obeliskLocalized
            case .hide(let isHidden):
                return (isHidden ? "移到隐藏书签?" : "恢复到书签?").obeliskLocalized
            case .archive(let isArchived):
                return (isArchived ? "归档书签?" : "恢复到书签?").obeliskLocalized
            case .assign(_, let collectionName):
                if let collectionName {
                    return String.localizedStringWithFormat("移到「%@」?".obeliskLocalized, collectionName)
                }
                return "移出分组?".obeliskLocalized
            }
        }

        var confirmButtonTitle: String {
            switch kind {
            case .pin(let isPinned):
                return isPinned
                    ? String(localized: "bookmark.action.pin", defaultValue: "置顶")
                    : "取消置顶".obeliskLocalized
            case .hide(let isHidden):
                return (isHidden ? "移到隐藏书签" : "恢复到书签").obeliskLocalized
            case .archive(let isArchived):
                return (isArchived ? "归档" : "恢复到书签").obeliskLocalized
            case .assign:
                return "移动".obeliskLocalized
            }
        }

        var isDestructive: Bool {
            switch kind {
            case .hide(true), .archive(true):
                return true
            default:
                return false
            }
        }
    }

    var visibleBookmarks: [Bookmark] {
        model.bookmarks.filter { !$0.isHidden && !isEffectivelyArchived($0) }
    }

    var hiddenBookmarks: [Bookmark] {
        model.bookmarks.filter { $0.isHidden && !isEffectivelyArchived($0) }
    }

    var filteredHiddenBookmarks: [Bookmark] {
        model.sortedBookmarks(hiddenBookmarks, sortMode: hiddenBookmarkListSortMode)
    }

    var archivedBookmarks: [Bookmark] {
        return model.bookmarks.filter { !$0.isHidden && model.isEffectivelyArchived($0) }
    }

    var bookmarkSections: [BookmarkListSection] {
        let pinnedSections = model.pinnedSections(
            sortMode: pinnedBookmarkListSortMode,
            showsSortControl: true
        )
        let recentBookmarks = model.recent
        let recentSections = recentBookmarks.isEmpty ? [] : [
            BookmarkListSection(
                title: "最近添加 (\(recentBookmarks.count))",
                bookmarks: recentBookmarks,
                referenceIndicatorSystemImage: FaviconReferenceBadge.systemImageName
            )
        ]
        let ungroupedSections = model.visibleUngroupedSections(
            sortMode: bookmarkListSortMode,
            showsSortControl: true
        )
        return pinnedSections + recentSections + ungroupedSections
    }

    var bookmarkDisplayMode: BookmarkDisplayMode {
        get {
            BookmarkDisplayMode(rawValue: bookmarkDisplayModeRaw) ?? .list
        }
        nonmutating set {
            bookmarkDisplayModeRaw = newValue.rawValue
        }
    }

    var bookmarkDisplayModeBinding: Binding<BookmarkDisplayMode> {
        Binding(
            get: { bookmarkDisplayMode },
            set: { bookmarkDisplayMode = $0 }
        )
    }

    var dateGridBookmarkSections: [BookmarkGridSection] {
        BookmarkGridSection.dateSections(from: visibleBookmarks)
    }

    var hiddenBookmarkDisplayMode: BookmarkDisplayMode {
        get {
            BookmarkDisplayMode(rawValue: hiddenBookmarkDisplayModeRaw) ?? .list
        }
        nonmutating set {
            hiddenBookmarkDisplayModeRaw = newValue.rawValue
        }
    }

    var hiddenBookmarkDisplayModeBinding: Binding<BookmarkDisplayMode> {
        Binding(
            get: { hiddenBookmarkDisplayMode },
            set: { hiddenBookmarkDisplayMode = $0 }
        )
    }

    var hiddenBookmarkDateGridSections: [BookmarkGridSection] {
        BookmarkGridSection.dateSections(from: hiddenBookmarks)
    }

    var collectionBookmarkSections: [BookmarkListSection] {
        model.visibleCollectionSections(
            sortMode: collectionListSortMode,
            includeEmptyCollections: true,
            showsSortControlOnFirstSection: true
        )
    }

    var collectionBookmarkDisplayMode: BookmarkDisplayMode {
        get {
            BookmarkDisplayMode(rawValue: collectionBookmarkDisplayModeRaw) ?? .list
        }
        nonmutating set {
            collectionBookmarkDisplayModeRaw = newValue.rawValue
        }
    }

    var collectionBookmarkDisplayModeBinding: Binding<BookmarkDisplayMode> {
        Binding(
            get: { collectionBookmarkDisplayMode },
            set: { collectionBookmarkDisplayMode = $0 }
        )
    }

    var collectionGridSections: [BookmarkGridSection] {
        collectionBookmarkSections.map { section in
            BookmarkGridSection(
                id: section.id,
                title: section.title ?? "分组".obeliskLocalized,
                subtitle: bookmarkCountSubtitle(section.bookmarks.count),
                bookmarks: section.bookmarks,
                collectionId: section.collectionId
            )
        }
    }

    var searchFilterOptions: [SearchFilter] {
        [.all] + model.collections.map { .collection($0.id) }
    }

    var effectiveSearchFilter: SearchFilter {
        switch searchFilter {
        case .all:
            return .all
        case .collection(let id):
            return model.collections.contains(where: { $0.id == id }) ? searchFilter : .all
        }
    }

    var searchFilterBinding: Binding<SearchFilter> {
        Binding(
            get: { effectiveSearchFilter },
            set: { searchFilter = $0 }
        )
    }

    func searchFilterTitle(for filter: SearchFilter) -> String {
        switch filter {
        case .all:
            return "全部".obeliskLocalized
        case .collection(let id):
            return model.collections.first(where: { $0.id == id })?.name ?? "分组".obeliskLocalized
        }
    }

    var effectiveSearchCollectionId: UUID? {
        if case .collection(let id) = effectiveSearchFilter {
            return id
        }
        return nil
    }

    var searchableBookmarks: [Bookmark] {
        model.searchBookmarks(matching: searchText, inCollection: effectiveSearchCollectionId)
    }

    var searchBookmarkSections: [BookmarkListSection] {
        model.bookmarkLibrarySections(
            for: searchableBookmarks,
            pinnedSortMode: pinnedBookmarkListSortMode,
            collectionSortMode: collectionListSortMode,
            ungroupedSortMode: bookmarkListSortMode
        )
    }

    var collectionAssignOptions: [BookmarkCollectionAssignOption] {
        var options = model.collections.map {
            BookmarkCollectionAssignOption(title: $0.name, collectionId: $0.id)
        }
        options.append(BookmarkCollectionAssignOption(title: "未分组".obeliskLocalized, collectionId: nil))
        return options
    }

    var menuBarOrderItems: [BookmarkMenuOrderItem] {
        BookmarkMenuSectionOrder.items(
            collections: model.collections,
            rawValue: menuBarSectionOrderRaw
        )
    }

    func saveMenuBarSectionOrder(_ ids: [BookmarkMenuSectionID]) {
        let encodedOrder = BookmarkMenuSectionOrder.encoded(ids)
        guard encodedOrder != menuBarSectionOrderRaw else { return }
        menuBarSectionOrderRaw = encodedOrder
        model.notifyMenuPresentationChanged()
    }

    @available(macOS 27.0, *)
    func moveMenuBarSections(
        using difference: ReorderDifference<BookmarkMenuSectionID, ReorderableSingleCollectionIdentifier>
    ) {
        let destinationID: BookmarkMenuSectionID?
        switch difference.destination.position {
        case .before(let id):
            destinationID = id
        case .end:
            destinationID = nil
        }

        let currentOrder = menuBarOrderItems.map(\.id)
        let updatedOrder = BookmarkMenuSectionOrder.moving(
            difference.sources,
            before: destinationID,
            in: currentOrder
        )
        saveMenuBarSectionOrder(updatedOrder)
    }

    func moveMenuBarSection(draggedID: BookmarkMenuSectionID, toIndex targetIndex: Int) {
        var ids = menuBarOrderItems.map(\.id)
        guard
            let sourceIndex = ids.firstIndex(of: draggedID),
            !ids.isEmpty
        else {
            return
        }

        let destinationIndex = min(max(targetIndex, 0), ids.count - 1)
        guard sourceIndex != destinationIndex else { return }

        let movedID = ids.remove(at: sourceIndex)
        ids.insert(movedID, at: destinationIndex)
        saveMenuBarSectionOrder(ids)
    }

    func menuBarOrderTargetIndex(
        startIndex: Int,
        translationY: CGFloat,
        itemCount: Int
    ) -> Int {
        guard itemCount > 0 else { return 0 }
        let proposedIndex = CGFloat(startIndex) + translationY / menuBarOrderRowHeight
        return min(max(Int(proposedIndex.rounded()), 0), itemCount - 1)
    }

    func stableMenuBarOrderTargetIndex(
        startIndex: Int,
        translationY: CGFloat,
        itemCount: Int
    ) -> Int {
        let proposedTargetIndex = menuBarOrderTargetIndex(
            startIndex: startIndex,
            translationY: translationY,
            itemCount: itemCount
        )
        let currentTargetIndex = menuBarDragTargetIndex ?? startIndex
        guard proposedTargetIndex != currentTargetIndex else {
            return proposedTargetIndex
        }

        let currentTargetTranslation = CGFloat(currentTargetIndex - startIndex) * menuBarOrderRowHeight
        let distanceFromCurrentTarget = abs(translationY - currentTargetTranslation)
        guard distanceFromCurrentTarget >= menuBarOrderRowHeight * 0.62 else {
            return currentTargetIndex
        }
        return proposedTargetIndex
    }

    func resetMenuBarOrderDrag() {
        draggingMenuBarSectionID = nil
        menuBarDragStartIndex = nil
        menuBarDragTargetIndex = nil
        menuBarDragOffsetY = 0
    }

    func menuBarOrderRowOffset(for index: Int, itemID: BookmarkMenuSectionID) -> CGFloat {
        guard
            let draggingMenuBarSectionID,
            let targetIndex = menuBarDragTargetIndex,
            let sourceIndex = menuBarDragStartIndex,
            draggingMenuBarSectionID != itemID
        else {
            return 0
        }

        if sourceIndex < targetIndex,
           index > sourceIndex,
           index <= targetIndex {
            return -menuBarOrderRowHeight
        }
        if targetIndex < sourceIndex,
           index >= targetIndex,
           index < sourceIndex {
            return menuBarOrderRowHeight
        }
        return 0
    }

    var hiddenBookmarkSections: [BookmarkListSection] {
        let bookmarks = filteredHiddenBookmarks
        return bookmarks.isEmpty ? [] : [BookmarkListSection(title: nil, bookmarks: bookmarks)]
    }

    var archivedBookmarkSections: [BookmarkListSection] {
        let bookmarks = archivedBookmarks
        return bookmarks.isEmpty ? [] : [BookmarkListSection(title: "归档书签", bookmarks: bookmarks)]
    }

    func isEffectivelyArchived(_ bookmark: Bookmark) -> Bool {
        model.isEffectivelyArchived(bookmark)
    }

    var bookmarkListSortMode: BookmarkListSortMode {
        get {
            BookmarkListSortMode(rawValue: bookmarkListSortModeRaw) ?? .name
        }
        nonmutating set {
            bookmarkListSortModeRaw = newValue.rawValue
            model.notifyMenuPresentationChanged()
        }
    }

    var pinnedBookmarkListSortMode: BookmarkListSortMode {
        get {
            BookmarkListSortMode(rawValue: pinnedBookmarkListSortModeRaw) ?? .name
        }
        nonmutating set {
            pinnedBookmarkListSortModeRaw = newValue.rawValue
            model.notifyMenuPresentationChanged()
        }
    }

    func updateBookmarkListSortMode(_ sortMode: BookmarkListSortMode, scope: BookmarkListSortScope?) {
        switch scope {
        case .pinned:
            pinnedBookmarkListSortMode = sortMode
        case .ungrouped:
            bookmarkListSortMode = sortMode
        case nil:
            bookmarkListSortMode = sortMode
        }
    }

    var bookmarkListSortModeBinding: Binding<BookmarkListSortMode> {
        Binding(
            get: { bookmarkListSortMode },
            set: { bookmarkListSortMode = $0 }
        )
    }

    var collectionListSortMode: BookmarkListSortMode {
        get {
            BookmarkListSortMode(rawValue: collectionListSortModeRaw) ?? .name
        }
        nonmutating set {
            collectionListSortModeRaw = newValue.rawValue
            model.notifyMenuPresentationChanged()
        }
    }

    var hiddenBookmarkListSortMode: BookmarkListSortMode {
        get {
            BookmarkListSortMode(rawValue: hiddenBookmarkListSortModeRaw) ?? .name
        }
        nonmutating set {
            hiddenBookmarkListSortModeRaw = newValue.rawValue
        }
    }

    var hiddenBookmarkListSortModeBinding: Binding<BookmarkListSortMode> {
        Binding(
            get: { hiddenBookmarkListSortMode },
            set: { hiddenBookmarkListSortMode = $0 }
        )
    }

    func consumePendingAddRequestIfNeeded() {
        guard let request = addRequest.consumePending() else { return }
        presentation = .add(
            seq: request.seq,
            prefilledURL: request.url,
            prefilledTitle: request.title,
            prefilledIsHidden: request.isHidden
        )
    }

    var selectedBookmark: Bookmark? {
        guard selection.count == 1, let id = selection.first else {
            return nil
        }
        return model.bookmarks.first { $0.id == id }
    }

    var selectedCollection: BookmarkCollection? {
        guard let selectedCollectionId, selection.isEmpty else { return nil }
        return model.collections.first { $0.id == selectedCollectionId }
    }

    var canDeleteSelection: Bool {
        !selection.isEmpty
    }

    var canUseSingleSelectionActions: Bool {
        selectedBookmark != nil
    }

    var selectedBookmarks: [Bookmark] {
        model.bookmarks.filter { selection.contains($0.id) }
    }

    var canTogglePinnedSelection: Bool {
        !selectedBookmarks.isEmpty
    }

    var selectedPinnedTargetState: Bool {
        selectedBookmarks.isEmpty || !selectedBookmarks.allSatisfy(\.isPinned)
    }

    var selectedPinnedSystemImage: String {
        selectedPinnedTargetState ? "pin" : "pin.slash"
    }

    var hiddenBookmarkExcludedURLKeywords: [String] {
        HiddenBookmarkKeywordExclusion.keywords(from: hiddenBookmarkExcludedURLKeywordsRaw)
    }

    var canDeleteCollectionPageSelection: Bool {
        !selection.isEmpty || selectedCollection != nil
    }

    var canEditCollectionPageSelection: Bool {
        selectedBookmark != nil || selectedCollection != nil
    }

    func requestDelete(ids: Set<Bookmark.ID>) {
        guard !ids.isEmpty else { return }
        deleteConfirmation = DeleteConfirmation(ids: ids)
    }

    func confirmDelete(_ confirmation: DeleteConfirmation) {
        model.delete(ids: confirmation.ids)
        selection.subtract(confirmation.ids)
    }

    func requestPinFromContextMenu(ids: Set<Bookmark.ID>) {
        let bookmarks = model.bookmarks.filter { ids.contains($0.id) }
        guard !bookmarks.isEmpty else { return }
        let isPinned = !bookmarks.allSatisfy(\.isPinned)
        contextMenuConfirmation = ContextMenuConfirmation(ids: ids, kind: .pin(isPinned: isPinned))
    }

    func requestHiddenFromContextMenu(ids: Set<Bookmark.ID>, isHidden: Bool) {
        guard !ids.isEmpty else { return }
        contextMenuConfirmation = ContextMenuConfirmation(ids: ids, kind: .hide(isHidden: isHidden))
    }

    func requestArchivedFromContextMenu(ids: Set<Bookmark.ID>, isArchived: Bool) {
        guard !ids.isEmpty else { return }
        contextMenuConfirmation = ContextMenuConfirmation(ids: ids, kind: .archive(isArchived: isArchived))
    }

    func requestAssignCollectionFromContextMenu(bookmarkIds: Set<Bookmark.ID>, collectionId: UUID?) {
        guard !bookmarkIds.isEmpty else { return }
        let collectionName = collectionId.flatMap { id in
            model.collections.first { $0.id == id }?.name
        }
        contextMenuConfirmation = ContextMenuConfirmation(
            ids: bookmarkIds,
            kind: .assign(collectionId: collectionId, collectionName: collectionName)
        )
    }

    func confirmContextMenuAction(_ confirmation: ContextMenuConfirmation) {
        switch confirmation.kind {
        case .pin(let isPinned):
            setPinned(isPinned, for: confirmation.ids)
        case .hide(let isHidden):
            setHidden(isHidden, for: confirmation.ids, showsToast: true)
        case .archive(let isArchived):
            setArchived(isArchived, for: confirmation.ids, showsToast: true)
        case .assign(let collectionId, _):
            assignCollection(bookmarkIds: confirmation.ids, collectionId: collectionId)
        }
    }

    func requestDeleteSelectedCollection() {
        guard let selectedCollection else { return }
        beginDeleteCollection(id: selectedCollection.id)
    }

    func requestRenameSelectedCollection() {
        guard let selectedCollection else { return }
        beginRenameCollection(id: selectedCollection.id)
    }

    func requestDeleteCollectionPageSelection() {
        if !selection.isEmpty {
            requestDelete(ids: selection)
        } else {
            requestDeleteSelectedCollection()
        }
    }

    func requestEditCollectionPageSelection() {
        if let bookmark = selectedBookmark {
            presentation = .edit(bookmark)
        } else {
            requestRenameSelectedCollection()
        }
    }

    func copyURL(_ bookmark: Bookmark) {
        copyURLs(of: [bookmark])
    }

    func copyURLs(of bookmarks: [Bookmark]) {
        guard !bookmarks.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bookmarks.map(\.url).joined(separator: "\n"), forType: .string)
        showToast(bookmarks.count > 1 ? "已复制 \(bookmarks.count) 个 URL" : "已复制 URL")
    }

    func setHidden(_ isHidden: Bool, for bookmark: Bookmark) {
        setHidden(isHidden, for: [bookmark.id], showsToast: false)
    }

    func setHidden(_ isHidden: Bool, for ids: Set<Bookmark.ID>, showsToast: Bool = false) {
        guard !ids.isEmpty else { return }
        if let errorMessage = model.setHidden(isHidden, for: ids) {
            model.errorMessage = errorMessage
        } else {
            selection.subtract(ids)
            if showsToast {
                if isHidden {
                    showToast(ids.count > 1 ? "已移到隐藏书签 \(ids.count) 个书签" : "已移到隐藏书签")
                } else {
                    showToast(ids.count > 1 ? "已恢复到书签 \(ids.count) 个书签" : "已恢复到书签")
                }
            }
        }
    }

    func setArchived(_ isArchived: Bool, for bookmark: Bookmark) {
        setArchived(isArchived, for: [bookmark.id], showsToast: false)
    }

    func setArchived(_ isArchived: Bool, for ids: Set<Bookmark.ID>, showsToast: Bool = false) {
        guard !ids.isEmpty else { return }
        if let errorMessage = model.setArchived(isArchived, for: ids) {
            model.errorMessage = errorMessage
        } else {
            selection.subtract(ids)
            if showsToast {
                if isArchived {
                    showToast(ids.count > 1 ? "已归档 \(ids.count) 个书签" : "已归档")
                } else {
                    showToast(ids.count > 1 ? "已恢复到书签 \(ids.count) 个书签" : "已恢复到书签")
                }
            }
        }
    }

    func setPinned(_ isPinned: Bool, for bookmark: Bookmark) {
        setPinned(isPinned, for: [bookmark.id])
    }

    func setPinned(_ isPinned: Bool, for ids: Set<Bookmark.ID>) {
        guard !ids.isEmpty else { return }
        if let errorMessage = model.setPinned(isPinned, for: ids) {
            model.errorMessage = errorMessage
        } else if isPinned {
            showToast(ids.count > 1 ? "已置顶 \(ids.count) 个书签" : "已置顶")
        } else {
            showToast(ids.count > 1 ? "已取消置顶 \(ids.count) 个书签" : "已取消置顶")
        }
    }

    func setPinned(for ids: Set<Bookmark.ID>) {
        let bookmarks = model.bookmarks.filter { ids.contains($0.id) }
        guard !bookmarks.isEmpty else { return }
        setPinned(!bookmarks.allSatisfy(\.isPinned), for: ids)
    }

    func togglePinnedSelection() {
        guard canTogglePinnedSelection else { return }
        setPinned(for: selection)
    }

    func openArchivedBookmark(_ bookmark: Bookmark) {
        openArchivedBookmarks([bookmark])
    }

    func openArchivedBookmarks(_ bookmarks: [Bookmark]) {
        guard !bookmarks.isEmpty else { return }
        for bookmark in bookmarks {
            if faviconLoader.image(for: bookmark.url) == nil {
                faviconLoader.refresh(urlString: bookmark.url)
            }
            model.openArchivedBookmark(bookmark)
        }
        selection.subtract(Set(bookmarks.map(\.id)))
    }

    func openBookmark(_ bookmark: Bookmark) {
        openBookmarks([bookmark])
    }

    func openBookmarks(_ bookmarks: [Bookmark]) {
        guard !bookmarks.isEmpty else { return }
        for bookmark in bookmarks {
            if faviconLoader.image(for: bookmark.url) == nil {
                faviconLoader.refresh(urlString: bookmark.url)
            }
            model.openBookmark(bookmark)
        }
        selection.subtract(Set(bookmarks.map(\.id)))
    }

    func syncArchiveSettings() {
        archiveAfterDays = BookmarksModel.clampedArchiveAfterDays(archiveAfterDays)
        model.reload()
    }

    func openHiddenBookmark(_ bookmark: Bookmark) {
        openHiddenBookmarks([bookmark])
    }

    func openHiddenBookmarks(_ bookmarks: [Bookmark]) {
        guard !bookmarks.isEmpty else { return }
        for bookmark in bookmarks {
            if faviconLoader.image(for: bookmark.url) == nil {
                faviconLoader.refresh(urlString: bookmark.url)
            }
            guard openHiddenBookmarksIncognito else {
                guard let url = URL(string: bookmark.url) else { continue }
                if NSWorkspace.shared.open(url) {
                    model.recordUsage(for: bookmark)
                }
                continue
            }

            switch PrivateBrowserOpener.openIncognito(urlString: bookmark.url) {
            case .opened:
                model.recordUsage(for: bookmark)
            case .unsupportedBrowser:
                showToast("当前默认浏览器不支持无痕打开", kind: .error)
                return
            case .invalidURL:
                showToast("网址格式不正确", kind: .error)
                return
            case .openFailed:
                showToast("无法打开无痕窗口", kind: .error)
                return
            case .automationPermissionRequired(.accessibility):
                showToast("请在“隐私与安全性 > 辅助功能”允许 Obelisk", kind: .error)
                PermissionSettingsGuide.open(.accessibility)
                return
            case .automationPermissionRequired(.appleEvents):
                showToast("请在“隐私与安全性 > 自动化”允许 Obelisk 控制默认浏览器", kind: .error)
                PermissionSettingsGuide.open(.automation)
                return
            }
        }
    }

    func syncMenuGroupLimits() {
        model.setMenuRecentGroupLimit(menuRecentGroupLimit)
    }

    func assignCollection(bookmarkIds: Set<Bookmark.ID>, collectionId: UUID?) {
        guard !bookmarkIds.isEmpty else { return }
        if let error = model.setBookmarkCollection(bookmarkIds: bookmarkIds, collectionId: collectionId) {
            showToast(error, kind: .error)
            return
        }
        if bookmarkIds.count > 1 {
            showToast("已移动 \(bookmarkIds.count) 个书签")
        }
    }

    func assignCollectionToSelection(collectionId: UUID?) {
        assignCollection(bookmarkIds: selection, collectionId: collectionId)
    }

    func createCollection() {
        if let error = model.createCollection(name: newCollectionName) {
            showToast(error, kind: .error)
        } else {
            newCollectionName = ""
            showToast("已创建分组")
        }
    }

    func renameCollection() {
        guard let collection = collectionToRename else { return }
        if let error = model.renameCollection(id: collection.id, name: renameCollectionName) {
            showToast(error, kind: .error)
        } else {
            collectionToRename = nil
            renameCollectionName = ""
            showToast("已重命名分组")
        }
    }

    func deleteCollection() {
        guard let collection = collectionToDelete else { return }
        if let error = model.deleteCollection(id: collection.id) {
            showToast(error, kind: .error)
        } else {
            collectionToDelete = nil
            selectedCollectionId = nil
            showToast("已删除分组")
        }
    }

    func beginRenameCollection(id: UUID) {
        guard let collection = model.collections.first(where: { $0.id == id }) else { return }
        collectionToRename = collection
        renameCollectionName = collection.name
    }

    func beginDeleteCollection(id: UUID) {
        guard let collection = model.collections.first(where: { $0.id == id }) else { return }
        collectionToDelete = collection
    }

    func addHiddenBookmarkExcludedURLKeyword() {
        let keyword = newHiddenBookmarkExcludedURLKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }

        var keywords = hiddenBookmarkExcludedURLKeywords
        guard !keywords.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) else {
            newHiddenBookmarkExcludedURLKeyword = ""
            return
        }
        keywords.append(keyword)
        hiddenBookmarkExcludedURLKeywordsRaw = HiddenBookmarkKeywordExclusion.encoded(keywords)
        newHiddenBookmarkExcludedURLKeyword = ""
    }

    func removeHiddenBookmarkExcludedURLKeyword(_ keyword: String) {
        let keywords = hiddenBookmarkExcludedURLKeywords.filter {
            $0.caseInsensitiveCompare(keyword) != .orderedSame
        }
        hiddenBookmarkExcludedURLKeywordsRaw = HiddenBookmarkKeywordExclusion.encoded(keywords)
    }

    var showsFullURLBinding: Binding<Bool> {
        Binding(
            get: { !showsURLHostOnly },
            set: { showsURLHostOnly = !$0 }
        )
    }

    var customTransparencyBinding: Binding<Bool> {
        Binding(
            get: { customTransparencyEnabled },
            set: { newValue in
                if newValue {
                    showCustomTransparencyAlert = true
                } else {
                    customTransparencyEnabled = false
                    windowSeeThrough = 0.0
                }
            }
        )
    }

    var sidebarIconTheme: SidebarIconTheme {
        SidebarIconTheme(rawValue: sidebarIconThemeRaw) ?? .professional
    }

    var sidebarIconThemeBinding: Binding<SidebarIconTheme> {
        Binding(
            get: { sidebarIconTheme },
            set: { sidebarIconThemeRaw = $0.rawValue }
        )
    }

    var sidebarIconStyle: SidebarIconStyle {
        SidebarIconStyle(rawValue: sidebarIconStyleRaw) ?? .tabler
    }

    var sidebarIconStyleBinding: Binding<SidebarIconStyle> {
        Binding(
            get: { sidebarIconStyle },
            set: { sidebarIconStyleRaw = $0.rawValue }
        )
    }

    var menuBarIconStyle: MenuBarIconStyle {
        MenuBarIconStyle(rawValue: menuBarIconStyleRaw) ?? .outline
    }

    var menuBarIconStyleBinding: Binding<MenuBarIconStyle> {
        Binding(
            get: { menuBarIconStyle },
            set: { menuBarIconStyleRaw = $0.rawValue }
        )
    }

    var optimizableTitleCountInScope: Int {
        let scope = selection.isEmpty ? nil : selection
        return model.bookmarks.filter { bookmark in
            (scope?.contains(bookmark.id) ?? true)
                && !bookmark.titleOptimized
                && TitleOptimizationPreferences.allowsOptimization(for: bookmark)
        }.count
    }

    var autoGroupableBookmarkCountInScope: Int {
        let scope = selection.isEmpty ? nil : selection
        return model.bookmarks.filter { bookmark in
            if let scope, !scope.contains(bookmark.id) {
                return false
            }
            return !bookmark.isHidden
                && !bookmark.isPinned
                && !model.isEffectivelyArchived(bookmark)
                && model.collectionId(for: bookmark.id) == nil
        }.count
    }

    func optimizeBookmarks(includeAutoGrouping: Bool) {
        Task {
            let outcome = await model.optimizeBookmarks(
                bookmarkIds: selection,
                options: BookmarkIntelligenceOptimizationOptions(
                    optimizeTitles: true,
                    autoGroup: includeAutoGrouping
                )
            )
            showToast(outcome.summary, kind: outcome.didChange ? .success : .error)
        }
    }

    func runAutoIntelligenceForNewBookmark(_ bookmark: Bookmark) {
        guard aiFeaturesEnabled else { return }

        let options = BookmarkIntelligenceOptimizationOptions.automatic(for: bookmark)
        guard options.optimizeTitles || options.autoGroup else { return }

        pendingAutoIntelligenceTask?.cancel()
        pendingAutoIntelligenceTask = Task {
            let outcome = await model.optimizeBookmarks(
                bookmarkIds: [bookmark.id],
                options: options
            )
            showToast(outcome.summary, kind: outcome.didChange ? .success : .error)
        }
    }

    func revertTitleOptimizations(bookmarkIds: Set<Bookmark.ID>) {
        if let message = model.revertTitleOptimizations(bookmarkIds: bookmarkIds) {
            showToast(message, kind: message.hasPrefix("已恢复") ? .success : .error)
        }
    }

    func showToast(_ message: String, kind: Toast.Kind = .success) {
        withAnimation(.spring(duration: 0.24, bounce: 0.18)) {
            toast = Toast(message: message.obeliskLocalized, kind: kind)
        }
    }

    var modelErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deleteConfirmation != nil },
            set: { if !$0 { deleteConfirmation = nil } }
        )
    }

    var contextMenuConfirmationBinding: Binding<Bool> {
        Binding(
            get: { contextMenuConfirmation != nil },
            set: { if !$0 { contextMenuConfirmation = nil } }
        )
    }

    var renameCollectionAlertBinding: Binding<Bool> {
        Binding(
            get: { collectionToRename != nil },
            set: { if !$0 { collectionToRename = nil } }
        )
    }

    var deleteCollectionAlertBinding: Binding<Bool> {
        Binding(
            get: { collectionToDelete != nil },
            set: { if !$0 { collectionToDelete = nil } }
        )
    }

    var customTransparencyAlertBinding: Binding<Bool> {
        Binding(
            get: { showCustomTransparencyAlert },
            set: { if !$0 { showCustomTransparencyAlert = false } }
        )
    }

    func toggleHiddenBookmarksPageVisibility() {
        showHiddenBookmarksPage.toggle()
    }

    var settingsPageBinding: Binding<SettingsPage?> {
        Binding<SettingsPage?>(
            get: { settingsPage },
            set: { nextPage in
                guard let nextPage else { return }
                if nextPage == .hiddenBookmarks, !hiddenBookmarksUnlocked {
                    Task {
                        guard await AuthenticationGate.authenticate(reason: "查看隐藏书签") else { return }
                        await MainActor.run {
                            hiddenBookmarksUnlocked = true
                            settingsPage = .hiddenBookmarks
                        }
                    }
                    return
                }
                if settingsPage == .hiddenBookmarks, nextPage != .hiddenBookmarks {
                    hiddenBookmarksUnlocked = false
                }
                settingsPage = nextPage
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            settingsSidebar
        } detail: {
            settingsDetail
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("侧边栏", systemImage: "sidebar.left") {
                    withAnimation {
                        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                    }
                }
                .help("显示或隐藏侧边栏")
                .accessibilityIdentifier("sidebarToggle")
            }
            ToolbarSpacer(.flexible)
            settingsToolbar
        }
        .toolbarBackgroundVisibility(
            windowTransparencyEnabled ? .hidden : .automatic,
            for: .windowToolbar
        )
        .overlay(alignment: .top) {
            toastView
        }
        .background {
            WindowTransparencyConfigurator(enabled: windowTransparencyEnabled)
                .frame(width: 0, height: 0)

            if windowTransparencyEnabled {
                WindowBackgroundBlur(materialAlpha: effectiveBlurAlpha)
                    .ignoresSafeArea()
            }

            Button {
                toggleHiddenBookmarksPageVisibility()
            } label: {
                EmptyView()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .sheet(item: $presentation) { kind in
            switch kind {
            case .add(_, let prefilledURL, let prefilledTitle, let prefilledIsHidden):
                BookmarkEditor(
                    mode: .add,
                    model: model,
                    prefilledURL: prefilledURL,
                    prefilledTitle: prefilledTitle,
                    prefilledIsHidden: prefilledIsHidden,
                    onBookmarkAdded: { bookmark in
                        runAutoIntelligenceForNewBookmark(bookmark)
                    }
                )
            case .edit(let bookmark):
                BookmarkEditor(mode: .edit(bookmark), model: model)
            }
        }
        .onAppear {
            intelligenceSettings.load()
            syncMenuGroupLimits()
            // First-launch path: the hotkey may have already bumped seq before
            // the view mounted. .onChange only fires on subsequent updates,
            // so we'd miss the initial request without this check. Subsequent
            // presses (window already open) hit .onChange below.
            consumePendingAddRequestIfNeeded()

            let modelRef = model
            let selectionBinding = $selection
            let presentationBinding = $presentation
            quickLookController.selection = { selectionBinding.wrappedValue }
            quickLookController.bookmarkLookup = { id in
                modelRef.bookmarks.first { $0.id == id }
            }
            quickLookController.isSheetPresented = { presentationBinding.wrappedValue != nil }
            quickLookController.install()
        }
        .onDisappear {
            intelligenceSettings.flush()
            quickLookController.uninstall()
        }
        .onChange(of: addRequest.seq) { _, _ in
            consumePendingAddRequestIfNeeded()
        }
        .onChange(of: settingsPage) { _, selectedPage in
            selectedCollectionId = nil
            searchFocusRequest = SearchFocusRequestResolver.resolve(
                current: searchFocusRequest,
                selectedPage: selectedPage
            )
        }
        .modifier(HiddenBookmarksLockingModifier(
            settingsPage: $settingsPage,
            hiddenBookmarksUnlocked: $hiddenBookmarksUnlocked,
            showHiddenBookmarksPage: $showHiddenBookmarksPage,
            selection: $selection
        ))
        .onChange(of: menuRecentGroupLimit) { _, _ in
            syncMenuGroupLimits()
        }
        .task(id: toast) {
            guard let currentToast = toast else { return }
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                guard toast == currentToast else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    toast = nil
                }
            }
        }
        .alert(
            "出错了",
            isPresented: modelErrorAlertBinding,
            presenting: model.errorMessage
        ) { _ in
            Button("好") { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        .alert(
            "删除书签?",
            isPresented: deleteConfirmationBinding,
            presenting: deleteConfirmation
        ) { confirmation in
            Button("取消", role: .cancel) {
                deleteConfirmation = nil
            }
            Button("删除", role: .destructive) {
                confirmDelete(confirmation)
                deleteConfirmation = nil
            }
        } message: { confirmation in
            Text("共计删除 \(confirmation.count) 个书签")
        }
        .alert(
            contextMenuConfirmation?.title ?? "",
            isPresented: contextMenuConfirmationBinding,
            presenting: contextMenuConfirmation
        ) { confirmation in
            Button("取消", role: .cancel) {
                contextMenuConfirmation = nil
            }
            Button(confirmation.confirmButtonTitle, role: confirmation.isDestructive ? .destructive : nil) {
                confirmContextMenuAction(confirmation)
                contextMenuConfirmation = nil
            }
        } message: { confirmation in
            Text(verbatim: String.localizedStringWithFormat(
                "共计 %lld 个书签".obeliskLocalized,
                confirmation.count
            ))
        }
        .modifier(ExtraAlerts(
            customTransparencyAlertBinding: customTransparencyAlertBinding,
            showCustomTransparencyAlert: $showCustomTransparencyAlert,
            customTransparencyEnabled: $customTransparencyEnabled,
            showNewCollectionDialog: $showNewCollectionDialog,
            newCollectionName: $newCollectionName,
            createCollection: createCollection,
            renameCollectionAlertBinding: renameCollectionAlertBinding,
            renameCollectionName: $renameCollectionName,
            collectionToRename: $collectionToRename,
            renameCollection: renameCollection,
            deleteCollectionAlertBinding: deleteCollectionAlertBinding,
            collectionToDelete: $collectionToDelete,
            deleteCollection: deleteCollection
        ))
    }

    @ViewBuilder
    var toastView: some View {
        if let toast {
            Label(toast.message, systemImage: toast.systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(toast.foregroundStyle)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .glassEffect(.regular, in: Capsule())
                .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
                .padding(.top, 12)
                .transition(.blurReplace)
                .allowsHitTesting(false)
                .accessibilityAddTraits(.isStaticText)
        }
    }

    var settingsSidebar: some View {
        AppKitSettingsSidebar(
            pages: visibleSettingsPages,
            selectedPage: settingsPageBinding,
            badgeCount: sidebarBadgeCount(for:),
            iconTheme: sidebarIconTheme,
            iconStyle: sidebarIconStyle,
            colorfulIconSize: sidebarIconTileSize,
            colorfulSymbolSize: sidebarIconSymbolSize,
            colorfulCornerRadius: sidebarIconCornerRadius,
            professionalIconSize: professionalSidebarIconSize
        )
        .navigationSplitViewColumnWidth(min: 150, ideal: 180)
    }

    var visibleSettingsPages: [SettingsPage] {
        SettingsPage.allCases.filter { page in
            page != .hiddenBookmarks || showHiddenBookmarksPage
        }
    }

    func sidebarBadgeCount(for page: SettingsPage) -> Int? {
        switch page {
        case .bookmarks:
            return visibleBookmarks.count
        case .search:
            return nil
        case .collections:
            return model.collections.count
        case .hiddenBookmarks:
            guard hiddenBookmarksUnlocked else { return nil }
            return hiddenBookmarks.count
        case .archive:
            return archivedBookmarks.count
        default:
            return nil
        }
    }

    var hiddenBookmarkSortMenu: some View {
        sortMenu(selection: hiddenBookmarkListSortModeBinding)
    }

    func sortMenu(selection: Binding<BookmarkListSortMode>) -> some View {
        CompactBorderedMenuPicker(
            options: Array(BookmarkListSortMode.allCases),
            selection: selection,
            title: { $0.title }
        )
    }

    @ViewBuilder
    var settingsDetail: some View {
        NavigationStack {
            switch settingsPage {
            case .bookmarks:
                bookmarkManagementPage
            case .search:
                searchPage
            case .collections:
                collectionsManagementPage
            case .hiddenBookmarks:
                hiddenBookmarkManagementPage
            case .archive:
                archivePage
            case .appearance:
                appearancePage
            case .menuBar:
                menuBarPage
            case .shortcuts:
                shortcutsPage
            case .ai:
                IntelligenceSettingsView(onMessage: { message, isError in
                    showToast(message, kind: isError ? .error : .success)
                }, settings: intelligenceSettings)
            case .cloudSync:
                CloudSyncSettingsView(cloudSync: cloudSync)
            case .privacy:
                privacyPage
            case .settings:
                GeneralSettingsView { message, isError in
                    showToast(message, kind: isError ? .error : .success)
                }
            }
        }
        .navigationTitle(settingsPage.title)
    }
}
