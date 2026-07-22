import AppKit
import Carbon.HIToolbox
import ObeliskCore
import ObeliskSync
import SwiftUI
import UniformTypeIdentifiers

private enum BookmarkDisplayMode: String, CaseIterable, Identifiable {
    case list
    case dateGrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "列表".obeliskLocalized
        case .dateGrid: return "表格".obeliskLocalized
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .dateGrid: return "square.grid.2x2"
        }
    }
}

extension View {
    /// Shared margins for all settings detail pages.
    func settingsContentMargins() -> some View {
        self
            .contentMargins(.horizontal, 18, for: .scrollContent)
            .contentMargins(.top, 0, for: .scrollContent)
    }
}

private struct CompactBorderedMenuPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(title(option)).tag(option)
            }
        }
        .pickerStyle(.menu)
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .labelsHidden()
        .frame(minWidth: 108, minHeight: 24)
    }
}

struct BookmarkManagerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: BookmarksModel
    @Bindable var cloudSync: CloudSyncController
    let faviconLoader: FaviconLoader
    let addRequest: AddBookmarkRequest
    @State private var selection: Set<Bookmark.ID> = []
    @State private var presentation: Presentation?
    @State private var deleteConfirmation: DeleteConfirmation?
    @State private var contextMenuConfirmation: ContextMenuConfirmation?
    @State private var toast: Toast?
    @State private var settingsPage: SettingsPage = .bookmarks
    @State private var selectedCollectionId: UUID?
    @State private var searchText = ""
    @State private var searchFilter: SearchFilter = .all
    @State private var searchFocusRequest = 0
    @State private var llmProfiles = LLMProfilesSettings()
    @State private var llmConfigMessage: String?
    @State private var isTestingLLMConfig = false
    @State private var hiddenBookmarksUnlocked = false
    @State private var quickLookController = QuickLookController()
    @AppStorage(SidebarIconTheme.storageKey) private var sidebarIconThemeRaw = SidebarIconTheme.professional.rawValue
    @AppStorage(SidebarIconStyle.storageKey) private var sidebarIconStyleRaw = SidebarIconStyle.tabler.rawValue
    @AppStorage(MenuBarIconStyle.storageKey) private var menuBarIconStyleRaw = MenuBarIconStyle.outline.rawValue
    private let sidebarIconTileSize = 22.0
    private let sidebarIconSymbolSize = 11.0
    private let sidebarIconCornerRadius = 6.0
    private let professionalSidebarIconSize = 15.0
    @AppStorage("showHiddenBookmarksPage") private var showHiddenBookmarksPage = false
    @AppStorage("showsURLHostOnly") private var showsURLHostOnly = false
    @AppStorage("menuRecentGroupLimit") private var menuRecentGroupLimit = 5
    @AppStorage(BrowserHistoryPreferences.menuRecordLimitStorageKey) private var menuBrowserHistoryLimit = BrowserHistoryPreferences.defaultMenuRecordLimit
    @AppStorage(BookmarksModel.autoArchiveEnabledKey) private var autoArchiveEnabled = false
    @AppStorage(BookmarksModel.archiveAfterDaysKey) private var archiveAfterDays = BookmarksModel.defaultArchiveAfterDays
    @AppStorage("windowTransparencyEnabled") private var windowTransparencyEnabled = false
    @AppStorage(ObeliskAppDefaults.openHiddenBookmarksIncognitoKey) private var openHiddenBookmarksIncognito = true
    @AppStorage(HiddenBookmarkKeywordExclusion.storageKey) private var hiddenBookmarkExcludedURLKeywordsRaw = ""
    @AppStorage(TitleOptimizationPreferences.autoOptimizeNewBookmarksKey) private var autoOptimizeNewBookmarks = false
    @AppStorage(TitleOptimizationPreferences.optimizeHiddenBookmarksKey) private var optimizeHiddenBookmarks = false
    @AppStorage(BookmarkAutoGroupingPreferences.autoGroupNewBookmarksKey) private var autoGroupNewBookmarks = false
    @AppStorage(BookmarksModel.aiFeaturesEnabledKey) private var aiFeaturesEnabled = true
    @AppStorage(TitleOptimizationTranslation.storageKey) private var translateNonChineseTitles = false
    @AppStorage(BookmarkListSortMode.bookmarksStorageKey) private var bookmarkListSortModeRaw = BookmarkListSortMode.name.rawValue
    @AppStorage(BookmarkListSortMode.pinnedStorageKey) private var pinnedBookmarkListSortModeRaw = BookmarkListSortMode.name.rawValue
    @AppStorage(BookmarkListSortMode.collectionsStorageKey) private var collectionListSortModeRaw = BookmarkListSortMode.name.rawValue
    @AppStorage(BookmarkListSortMode.hiddenStorageKey) private var hiddenBookmarkListSortModeRaw = BookmarkListSortMode.name.rawValue
    @AppStorage("bookmarkDisplayMode") private var bookmarkDisplayModeRaw = BookmarkDisplayMode.list.rawValue
    @AppStorage("hiddenBookmarkDisplayMode") private var hiddenBookmarkDisplayModeRaw = BookmarkDisplayMode.list.rawValue
    @AppStorage("collectionBookmarkDisplayMode") private var collectionBookmarkDisplayModeRaw = BookmarkDisplayMode.list.rawValue
    @AppStorage(BookmarkMenuSectionOrder.storageKey) private var menuBarSectionOrderRaw = ""
    // 0 = 完全不透明（默认毛玻璃材质满强度）；上限 0.5（再透可读性会崩）。
    @AppStorage("windowSeeThrough") private var windowSeeThrough: Double = 0.0
    @AppStorage("customTransparencyEnabled") private var customTransparencyEnabled = false
    @State private var showCustomTransparencyAlert = false
    @State private var showLanguageRestartAlert = false
    @AppStorage(AppLanguagePreference.storageKey) private var appLanguagePreferenceRaw = AppLanguagePreference.auto.rawValue
    @State private var showNewCollectionDialog = false
    @State private var newCollectionName = ""
    @State private var collectionToRename: BookmarkCollection?
    @State private var renameCollectionName = ""
    @State private var collectionToDelete: BookmarkCollection?
    @State private var newHiddenBookmarkExcludedURLKeyword = ""
    @State private var pendingAutoIntelligenceTask: Task<Void, Never>?
    @State private var pendingLLMConfigSaveTask: Task<Void, Never>?
    @State private var draggingMenuBarSectionID: BookmarkMenuSectionID?
    @State private var menuBarDragStartIndex: Int?
    @State private var menuBarDragTargetIndex: Int?
    @State private var menuBarDragOffsetY: CGFloat = 0
    @State private var launchAtLoginEnabled = LoginItemController.isEnabled
    private let menuBarOrderRowHeight: CGFloat = 50
    private var menuBarOrderBackgroundColor: Color {
        switch colorScheme {
        case .dark:
            return Color(red: 39 / 255, green: 41 / 255, blue: 54 / 255)
        default:
            return Color(red: 247 / 255, green: 247 / 255, blue: 247 / 255)
        }
    }

    private var menuBarOrderTransparentBackgroundColor: Color {
        switch colorScheme {
        case .dark:
            return Color.white.opacity(0.04)
        default:
            return Color.black.opacity(0.04)
        }
    }

    private var effectiveBlurAlpha: Double {
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
        case browserHistory
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
            case .bookmarks, .collections, .browserHistory, .search, .hiddenBookmarks, .archive: return .content
            case .appearance, .menuBar, .shortcuts:     return .preferences
            case .ai, .cloudSync, .privacy, .settings:  return .advanced
            }
        }

        var title: String {
            switch self {
            case .bookmarks:       return "书签".obeliskLocalized
            case .search:          return "搜索".obeliskLocalized
            case .collections:     return "分组".obeliskLocalized
            case .browserHistory:  return "最近浏览".obeliskLocalized
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
            case .browserHistory:  return "clock.fill"
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
            case .browserHistory:  return "clock"
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

    private var visibleBookmarks: [Bookmark] {
        model.bookmarks.filter { !$0.isHidden && !isEffectivelyArchived($0) }
    }

    private var hiddenBookmarks: [Bookmark] {
        model.bookmarks.filter { $0.isHidden && !isEffectivelyArchived($0) }
    }

    private var filteredHiddenBookmarks: [Bookmark] {
        model.sortedBookmarks(hiddenBookmarks, sortMode: hiddenBookmarkListSortMode)
    }

    private var archivedBookmarks: [Bookmark] {
        return model.bookmarks.filter { !$0.isHidden && model.isEffectivelyArchived($0) }
    }

    private var bookmarkSections: [BookmarkListSection] {
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

    private var bookmarkDisplayMode: BookmarkDisplayMode {
        get {
            BookmarkDisplayMode(rawValue: bookmarkDisplayModeRaw) ?? .list
        }
        nonmutating set {
            bookmarkDisplayModeRaw = newValue.rawValue
        }
    }

    private var bookmarkDisplayModeBinding: Binding<BookmarkDisplayMode> {
        Binding(
            get: { bookmarkDisplayMode },
            set: { bookmarkDisplayMode = $0 }
        )
    }

    private var dateGridBookmarkSections: [BookmarkGridSection] {
        BookmarkGridSection.dateSections(from: visibleBookmarks)
    }

    private var hiddenBookmarkDisplayMode: BookmarkDisplayMode {
        get {
            BookmarkDisplayMode(rawValue: hiddenBookmarkDisplayModeRaw) ?? .list
        }
        nonmutating set {
            hiddenBookmarkDisplayModeRaw = newValue.rawValue
        }
    }

    private var hiddenBookmarkDisplayModeBinding: Binding<BookmarkDisplayMode> {
        Binding(
            get: { hiddenBookmarkDisplayMode },
            set: { hiddenBookmarkDisplayMode = $0 }
        )
    }

    private var hiddenBookmarkDateGridSections: [BookmarkGridSection] {
        BookmarkGridSection.dateSections(from: hiddenBookmarks)
    }

    private var collectionBookmarkSections: [BookmarkListSection] {
        model.visibleCollectionSections(
            sortMode: collectionListSortMode,
            includeEmptyCollections: true,
            showsSortControlOnFirstSection: true
        )
    }

    private var collectionBookmarkDisplayMode: BookmarkDisplayMode {
        get {
            BookmarkDisplayMode(rawValue: collectionBookmarkDisplayModeRaw) ?? .list
        }
        nonmutating set {
            collectionBookmarkDisplayModeRaw = newValue.rawValue
        }
    }

    private var collectionBookmarkDisplayModeBinding: Binding<BookmarkDisplayMode> {
        Binding(
            get: { collectionBookmarkDisplayMode },
            set: { collectionBookmarkDisplayMode = $0 }
        )
    }

    private var collectionGridSections: [BookmarkGridSection] {
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

    private var searchFilterOptions: [SearchFilter] {
        [.all] + model.collections.map { .collection($0.id) }
    }

    private var effectiveSearchFilter: SearchFilter {
        switch searchFilter {
        case .all:
            return .all
        case .collection(let id):
            return model.collections.contains(where: { $0.id == id }) ? searchFilter : .all
        }
    }

    private var searchFilterBinding: Binding<SearchFilter> {
        Binding(
            get: { effectiveSearchFilter },
            set: { searchFilter = $0 }
        )
    }

    private func searchFilterTitle(for filter: SearchFilter) -> String {
        switch filter {
        case .all:
            return "全部".obeliskLocalized
        case .collection(let id):
            return model.collections.first(where: { $0.id == id })?.name ?? "分组".obeliskLocalized
        }
    }

    private var effectiveSearchCollectionId: UUID? {
        if case .collection(let id) = effectiveSearchFilter {
            return id
        }
        return nil
    }

    private var searchableBookmarks: [Bookmark] {
        model.searchBookmarks(matching: searchText, inCollection: effectiveSearchCollectionId)
    }

    private var searchBookmarkSections: [BookmarkListSection] {
        model.bookmarkLibrarySections(
            for: searchableBookmarks,
            pinnedSortMode: pinnedBookmarkListSortMode,
            collectionSortMode: collectionListSortMode,
            ungroupedSortMode: bookmarkListSortMode
        )
    }

    private var collectionAssignOptions: [BookmarkCollectionAssignOption] {
        var options = model.collections.map {
            BookmarkCollectionAssignOption(title: $0.name, collectionId: $0.id)
        }
        options.append(BookmarkCollectionAssignOption(title: "未分组".obeliskLocalized, collectionId: nil))
        return options
    }

    private var menuBarOrderItems: [BookmarkMenuOrderItem] {
        BookmarkMenuSectionOrder.items(
            collections: model.collections,
            rawValue: menuBarSectionOrderRaw
        )
    }

    private func saveMenuBarSectionOrder(_ ids: [BookmarkMenuSectionID]) {
        let encodedOrder = BookmarkMenuSectionOrder.encoded(ids)
        guard encodedOrder != menuBarSectionOrderRaw else { return }
        menuBarSectionOrderRaw = encodedOrder
        model.notifyMenuPresentationChanged()
    }

    @available(macOS 27.0, *)
    private func moveMenuBarSections(
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

    private func moveMenuBarSection(draggedID: BookmarkMenuSectionID, toIndex targetIndex: Int) {
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

    private func menuBarOrderTargetIndex(
        startIndex: Int,
        translationY: CGFloat,
        itemCount: Int
    ) -> Int {
        guard itemCount > 0 else { return 0 }
        let proposedIndex = CGFloat(startIndex) + translationY / menuBarOrderRowHeight
        return min(max(Int(proposedIndex.rounded()), 0), itemCount - 1)
    }

    private func stableMenuBarOrderTargetIndex(
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

    private func resetMenuBarOrderDrag() {
        draggingMenuBarSectionID = nil
        menuBarDragStartIndex = nil
        menuBarDragTargetIndex = nil
        menuBarDragOffsetY = 0
    }

    private func menuBarOrderRowOffset(for index: Int, itemID: BookmarkMenuSectionID) -> CGFloat {
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

    private var hiddenBookmarkSections: [BookmarkListSection] {
        let bookmarks = filteredHiddenBookmarks
        return bookmarks.isEmpty ? [] : [BookmarkListSection(title: nil, bookmarks: bookmarks)]
    }

    private var archivedBookmarkSections: [BookmarkListSection] {
        let bookmarks = archivedBookmarks
        return bookmarks.isEmpty ? [] : [BookmarkListSection(title: "归档书签", bookmarks: bookmarks)]
    }

    private func isEffectivelyArchived(_ bookmark: Bookmark) -> Bool {
        model.isEffectivelyArchived(bookmark)
    }

    private var bookmarkListSortMode: BookmarkListSortMode {
        get {
            BookmarkListSortMode(rawValue: bookmarkListSortModeRaw) ?? .name
        }
        nonmutating set {
            bookmarkListSortModeRaw = newValue.rawValue
            model.notifyMenuPresentationChanged()
        }
    }

    private var pinnedBookmarkListSortMode: BookmarkListSortMode {
        get {
            BookmarkListSortMode(rawValue: pinnedBookmarkListSortModeRaw) ?? .name
        }
        nonmutating set {
            pinnedBookmarkListSortModeRaw = newValue.rawValue
            model.notifyMenuPresentationChanged()
        }
    }

    private func updateBookmarkListSortMode(_ sortMode: BookmarkListSortMode, scope: BookmarkListSortScope?) {
        switch scope {
        case .pinned:
            pinnedBookmarkListSortMode = sortMode
        case .ungrouped:
            bookmarkListSortMode = sortMode
        case nil:
            bookmarkListSortMode = sortMode
        }
    }

    private var bookmarkListSortModeBinding: Binding<BookmarkListSortMode> {
        Binding(
            get: { bookmarkListSortMode },
            set: { bookmarkListSortMode = $0 }
        )
    }

    private var collectionListSortMode: BookmarkListSortMode {
        get {
            BookmarkListSortMode(rawValue: collectionListSortModeRaw) ?? .name
        }
        nonmutating set {
            collectionListSortModeRaw = newValue.rawValue
            model.notifyMenuPresentationChanged()
        }
    }

    private var hiddenBookmarkListSortMode: BookmarkListSortMode {
        get {
            BookmarkListSortMode(rawValue: hiddenBookmarkListSortModeRaw) ?? .name
        }
        nonmutating set {
            hiddenBookmarkListSortModeRaw = newValue.rawValue
        }
    }

    private var hiddenBookmarkListSortModeBinding: Binding<BookmarkListSortMode> {
        Binding(
            get: { hiddenBookmarkListSortMode },
            set: { hiddenBookmarkListSortMode = $0 }
        )
    }

    private func consumePendingAddRequestIfNeeded() {
        guard let request = addRequest.consumePending() else { return }
        presentation = .add(
            seq: request.seq,
            prefilledURL: request.url,
            prefilledTitle: request.title,
            prefilledIsHidden: request.isHidden
        )
    }

    private var selectedBookmark: Bookmark? {
        guard selection.count == 1, let id = selection.first else {
            return nil
        }
        return model.bookmarks.first { $0.id == id }
    }

    private var selectedCollection: BookmarkCollection? {
        guard let selectedCollectionId, selection.isEmpty else { return nil }
        return model.collections.first { $0.id == selectedCollectionId }
    }

    private var canDeleteSelection: Bool {
        !selection.isEmpty
    }

    private var canUseSingleSelectionActions: Bool {
        selectedBookmark != nil
    }

    private var selectedBookmarks: [Bookmark] {
        model.bookmarks.filter { selection.contains($0.id) }
    }

    private var canTogglePinnedSelection: Bool {
        !selectedBookmarks.isEmpty
    }

    private var selectedPinnedTargetState: Bool {
        selectedBookmarks.isEmpty || !selectedBookmarks.allSatisfy(\.isPinned)
    }

    private var selectedPinnedSystemImage: String {
        selectedPinnedTargetState ? "pin" : "pin.slash"
    }

    private var hiddenBookmarkExcludedURLKeywords: [String] {
        HiddenBookmarkKeywordExclusion.keywords(from: hiddenBookmarkExcludedURLKeywordsRaw)
    }

    private var canDeleteCollectionPageSelection: Bool {
        !selection.isEmpty || selectedCollection != nil
    }

    private var canEditCollectionPageSelection: Bool {
        selectedBookmark != nil || selectedCollection != nil
    }

    private func requestDelete(ids: Set<Bookmark.ID>) {
        guard !ids.isEmpty else { return }
        deleteConfirmation = DeleteConfirmation(ids: ids)
    }

    private func confirmDelete(_ confirmation: DeleteConfirmation) {
        model.delete(ids: confirmation.ids)
        selection.subtract(confirmation.ids)
    }

    private func requestPinFromContextMenu(ids: Set<Bookmark.ID>) {
        let bookmarks = model.bookmarks.filter { ids.contains($0.id) }
        guard !bookmarks.isEmpty else { return }
        let isPinned = !bookmarks.allSatisfy(\.isPinned)
        contextMenuConfirmation = ContextMenuConfirmation(ids: ids, kind: .pin(isPinned: isPinned))
    }

    private func requestHiddenFromContextMenu(ids: Set<Bookmark.ID>, isHidden: Bool) {
        guard !ids.isEmpty else { return }
        contextMenuConfirmation = ContextMenuConfirmation(ids: ids, kind: .hide(isHidden: isHidden))
    }

    private func requestArchivedFromContextMenu(ids: Set<Bookmark.ID>, isArchived: Bool) {
        guard !ids.isEmpty else { return }
        contextMenuConfirmation = ContextMenuConfirmation(ids: ids, kind: .archive(isArchived: isArchived))
    }

    private func requestAssignCollectionFromContextMenu(bookmarkIds: Set<Bookmark.ID>, collectionId: UUID?) {
        guard !bookmarkIds.isEmpty else { return }
        let collectionName = collectionId.flatMap { id in
            model.collections.first { $0.id == id }?.name
        }
        contextMenuConfirmation = ContextMenuConfirmation(
            ids: bookmarkIds,
            kind: .assign(collectionId: collectionId, collectionName: collectionName)
        )
    }

    private func confirmContextMenuAction(_ confirmation: ContextMenuConfirmation) {
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

    private func requestDeleteSelectedCollection() {
        guard let selectedCollection else { return }
        beginDeleteCollection(id: selectedCollection.id)
    }

    private func requestRenameSelectedCollection() {
        guard let selectedCollection else { return }
        beginRenameCollection(id: selectedCollection.id)
    }

    private func requestDeleteCollectionPageSelection() {
        if !selection.isEmpty {
            requestDelete(ids: selection)
        } else {
            requestDeleteSelectedCollection()
        }
    }

    private func requestEditCollectionPageSelection() {
        if let bookmark = selectedBookmark {
            presentation = .edit(bookmark)
        } else {
            requestRenameSelectedCollection()
        }
    }

    private func copyURL(_ bookmark: Bookmark) {
        copyURLs(of: [bookmark])
    }

    private func copyURLs(of bookmarks: [Bookmark]) {
        guard !bookmarks.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bookmarks.map(\.url).joined(separator: "\n"), forType: .string)
        showToast(bookmarks.count > 1 ? "已复制 \(bookmarks.count) 个 URL" : "已复制 URL")
    }

    private func setHidden(_ isHidden: Bool, for bookmark: Bookmark) {
        setHidden(isHidden, for: [bookmark.id], showsToast: false)
    }

    private func setHidden(_ isHidden: Bool, for ids: Set<Bookmark.ID>, showsToast: Bool = false) {
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

    private func setArchived(_ isArchived: Bool, for bookmark: Bookmark) {
        setArchived(isArchived, for: [bookmark.id], showsToast: false)
    }

    private func setArchived(_ isArchived: Bool, for ids: Set<Bookmark.ID>, showsToast: Bool = false) {
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

    private func setPinned(_ isPinned: Bool, for bookmark: Bookmark) {
        setPinned(isPinned, for: [bookmark.id])
    }

    private func setPinned(_ isPinned: Bool, for ids: Set<Bookmark.ID>) {
        guard !ids.isEmpty else { return }
        if let errorMessage = model.setPinned(isPinned, for: ids) {
            model.errorMessage = errorMessage
        } else if isPinned {
            showToast(ids.count > 1 ? "已置顶 \(ids.count) 个书签" : "已置顶")
        } else {
            showToast(ids.count > 1 ? "已取消置顶 \(ids.count) 个书签" : "已取消置顶")
        }
    }

    private func setPinned(for ids: Set<Bookmark.ID>) {
        let bookmarks = model.bookmarks.filter { ids.contains($0.id) }
        guard !bookmarks.isEmpty else { return }
        setPinned(!bookmarks.allSatisfy(\.isPinned), for: ids)
    }

    private func togglePinnedSelection() {
        guard canTogglePinnedSelection else { return }
        setPinned(for: selection)
    }

    private func openArchivedBookmark(_ bookmark: Bookmark) {
        openArchivedBookmarks([bookmark])
    }

    private func openArchivedBookmarks(_ bookmarks: [Bookmark]) {
        guard !bookmarks.isEmpty else { return }
        for bookmark in bookmarks {
            if faviconLoader.image(for: bookmark.url) == nil {
                faviconLoader.refresh(urlString: bookmark.url)
            }
            model.openArchivedBookmark(bookmark)
        }
        selection.subtract(Set(bookmarks.map(\.id)))
    }

    private func openBookmark(_ bookmark: Bookmark) {
        openBookmarks([bookmark])
    }

    private func openBookmarks(_ bookmarks: [Bookmark]) {
        guard !bookmarks.isEmpty else { return }
        for bookmark in bookmarks {
            if faviconLoader.image(for: bookmark.url) == nil {
                faviconLoader.refresh(urlString: bookmark.url)
            }
            model.openBookmark(bookmark)
        }
        selection.subtract(Set(bookmarks.map(\.id)))
    }

    private func syncArchiveSettings() {
        archiveAfterDays = BookmarksModel.clampedArchiveAfterDays(archiveAfterDays)
        model.reload()
    }

    private func refreshFavicon(for bookmark: Bookmark) {
        refreshFavicons(for: [bookmark])
    }

    private func refreshFavicons(for bookmarks: [Bookmark]) {
        guard !bookmarks.isEmpty else { return }
        for bookmark in bookmarks {
            faviconLoader.refresh(urlString: bookmark.url)
        }
        showToast(bookmarks.count > 1 ? "已刷新 \(bookmarks.count) 个 favicon" : "刷新 favicon 成功")
    }

    private func openHiddenBookmark(_ bookmark: Bookmark) {
        openHiddenBookmarks([bookmark])
    }

    private func openHiddenBookmarks(_ bookmarks: [Bookmark]) {
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
                showToast("请在“隐私与安全性 > 自动化”允许 Obelisk 控制 Dia", kind: .error)
                PermissionSettingsGuide.open(.automation)
                return
            }
        }
    }

    private func syncMenuGroupLimits() {
        model.setMenuRecentGroupLimit(menuRecentGroupLimit)
    }

    private func assignCollection(bookmarkIds: Set<Bookmark.ID>, collectionId: UUID?) {
        guard !bookmarkIds.isEmpty else { return }
        if let error = model.setBookmarkCollection(bookmarkIds: bookmarkIds, collectionId: collectionId) {
            showToast(error, kind: .error)
            return
        }
        if bookmarkIds.count > 1 {
            showToast("已移动 \(bookmarkIds.count) 个书签")
        }
    }

    private func assignCollectionToSelection(collectionId: UUID?) {
        assignCollection(bookmarkIds: selection, collectionId: collectionId)
    }

    private func createCollection() {
        if let error = model.createCollection(name: newCollectionName) {
            showToast(error, kind: .error)
        } else {
            newCollectionName = ""
            showToast("已创建分组")
        }
    }

    private func renameCollection() {
        guard let collection = collectionToRename else { return }
        if let error = model.renameCollection(id: collection.id, name: renameCollectionName) {
            showToast(error, kind: .error)
        } else {
            collectionToRename = nil
            renameCollectionName = ""
            showToast("已重命名分组")
        }
    }

    private func deleteCollection() {
        guard let collection = collectionToDelete else { return }
        if let error = model.deleteCollection(id: collection.id) {
            showToast(error, kind: .error)
        } else {
            collectionToDelete = nil
            selectedCollectionId = nil
            showToast("已删除分组")
        }
    }

    private func beginRenameCollection(id: UUID) {
        guard let collection = model.collections.first(where: { $0.id == id }) else { return }
        collectionToRename = collection
        renameCollectionName = collection.name
    }

    private func beginDeleteCollection(id: UUID) {
        guard let collection = model.collections.first(where: { $0.id == id }) else { return }
        collectionToDelete = collection
    }

    private func addHiddenBookmarkExcludedURLKeyword() {
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

    private func removeHiddenBookmarkExcludedURLKeyword(_ keyword: String) {
        let keywords = hiddenBookmarkExcludedURLKeywords.filter {
            $0.caseInsensitiveCompare(keyword) != .orderedSame
        }
        hiddenBookmarkExcludedURLKeywordsRaw = HiddenBookmarkKeywordExclusion.encoded(keywords)
    }

    private var showsFullURLBinding: Binding<Bool> {
        Binding(
            get: { !showsURLHostOnly },
            set: { showsURLHostOnly = !$0 }
        )
    }

    private var customTransparencyBinding: Binding<Bool> {
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

    private var sidebarIconTheme: SidebarIconTheme {
        SidebarIconTheme(rawValue: sidebarIconThemeRaw) ?? .professional
    }

    private var sidebarIconThemeBinding: Binding<SidebarIconTheme> {
        Binding(
            get: { sidebarIconTheme },
            set: { sidebarIconThemeRaw = $0.rawValue }
        )
    }

    private var sidebarIconStyle: SidebarIconStyle {
        SidebarIconStyle(rawValue: sidebarIconStyleRaw) ?? .tabler
    }

    private var sidebarIconStyleBinding: Binding<SidebarIconStyle> {
        Binding(
            get: { sidebarIconStyle },
            set: { sidebarIconStyleRaw = $0.rawValue }
        )
    }

    private var menuBarIconStyle: MenuBarIconStyle {
        MenuBarIconStyle(rawValue: menuBarIconStyleRaw) ?? .outline
    }

    private var menuBarIconStyleBinding: Binding<MenuBarIconStyle> {
        Binding(
            get: { menuBarIconStyle },
            set: { menuBarIconStyleRaw = $0.rawValue }
        )
    }

    private var optimizableTitleCountInScope: Int {
        let scope = selection.isEmpty ? nil : selection
        return model.bookmarks.filter { bookmark in
            (scope?.contains(bookmark.id) ?? true)
                && !bookmark.titleOptimized
                && TitleOptimizationPreferences.allowsOptimization(for: bookmark)
        }.count
    }

    private var autoGroupableBookmarkCountInScope: Int {
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

    private func optimizeBookmarks(includeAutoGrouping: Bool) {
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

    private func runAutoIntelligenceForNewBookmark(_ bookmark: Bookmark) {
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

    private func revertTitleOptimizations(bookmarkIds: Set<Bookmark.ID>) {
        if let message = model.revertTitleOptimizations(bookmarkIds: bookmarkIds) {
            showToast(message, kind: message.hasPrefix("已恢复") ? .success : .error)
        }
    }

    private func showToast(_ message: String, kind: Toast.Kind = .success) {
        withAnimation(.spring(duration: 0.24, bounce: 0.18)) {
            toast = Toast(message: message.obeliskLocalized, kind: kind)
        }
    }

    private var llmConfigStore: LLMConfigStore {
        LLMConfigStore()
    }

    private func loadLLMConfig() {
        llmProfiles = llmConfigStore.loadProfiles()
    }

    private func persistLLMConfig(_ profiles: LLMProfilesSettings) {
        llmProfiles = profiles
        pendingLLMConfigSaveTask?.cancel()
        pendingLLMConfigSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                try? LLMConfigStore().save(profiles)
            }.value
        }
    }

    private func testLLMConfig() {
        guard !isTestingLLMConfig else { return }
        isTestingLLMConfig = true
        let config = llmProfiles.activeConfig
        Task {
            do {
                _ = try await TitleOptimizer().benchmark(config: config)
                showToast("连接成功")
            } catch {
                showToast("连接失败", kind: .error)
            }
            isTestingLLMConfig = false
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { setLaunchAtLoginEnabled($0) }
        )
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = LoginItemController.isEnabled
    }

    private func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        let previousValue = launchAtLoginEnabled
        launchAtLoginEnabled = isEnabled

        do {
            try LoginItemController.setEnabled(isEnabled)
            refreshLaunchAtLoginState()
            if launchAtLoginEnabled == isEnabled {
                showToast(isEnabled ? "已开启登录时启动" : "已关闭登录时启动")
            } else {
                showToast("请在系统设置中允许 Obelisk 登录时启动", kind: .error)
            }
        } catch {
            launchAtLoginEnabled = previousValue
            showToast(error.localizedDescription, kind: .error)
        }
    }

    private var modelErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deleteConfirmation != nil },
            set: { if !$0 { deleteConfirmation = nil } }
        )
    }

    private var contextMenuConfirmationBinding: Binding<Bool> {
        Binding(
            get: { contextMenuConfirmation != nil },
            set: { if !$0 { contextMenuConfirmation = nil } }
        )
    }

    private var llmConfigAlertBinding: Binding<Bool> {
        Binding(
            get: { llmConfigMessage != nil },
            set: { if !$0 { llmConfigMessage = nil } }
        )
    }

    private var renameCollectionAlertBinding: Binding<Bool> {
        Binding(
            get: { collectionToRename != nil },
            set: { if !$0 { collectionToRename = nil } }
        )
    }

    private var deleteCollectionAlertBinding: Binding<Bool> {
        Binding(
            get: { collectionToDelete != nil },
            set: { if !$0 { collectionToDelete = nil } }
        )
    }

    private var customTransparencyAlertBinding: Binding<Bool> {
        Binding(
            get: { showCustomTransparencyAlert },
            set: { if !$0 { showCustomTransparencyAlert = false } }
        )
    }

    private func toggleHiddenBookmarksPageVisibility() {
        showHiddenBookmarksPage.toggle()
    }

    private var settingsPageBinding: Binding<SettingsPage?> {
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
        NavigationSplitView {
            settingsSidebar
        } detail: {
            settingsDetail
        }
        .toolbar {
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
            loadLLMConfig()
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
            pendingLLMConfigSaveTask?.cancel()
            let profiles = llmProfiles
            Task.detached(priority: .utility) {
                try? LLMConfigStore().save(profiles)
            }
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
        .alert(
            "提示",
            isPresented: llmConfigAlertBinding,
            presenting: llmConfigMessage
        ) { _ in
            Button("好") { llmConfigMessage = nil }
        } message: { message in
            Text(message)
        }
        .alert(
            "重新打开 Obelisk?",
            isPresented: $showLanguageRestartAlert
        ) {
            Button("稍后", role: .cancel) {}
            Button("重新打开") {
                AppRelauncher.relaunch()
            }
        } message: {
            Text("语言将在重新打开后生效")
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
    private var toastView: some View {
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

    private var settingsSidebar: some View {
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

    private var visibleSettingsPages: [SettingsPage] {
        SettingsPage.allCases.filter { page in
            page != .hiddenBookmarks || showHiddenBookmarksPage
        }
    }

    private func sidebarBadgeCount(for page: SettingsPage) -> Int? {
        switch page {
        case .bookmarks:
            return visibleBookmarks.count
        case .search:
            return nil
        case .collections:
            return model.collections.count
        case .browserHistory:
            return nil
        case .hiddenBookmarks:
            guard hiddenBookmarksUnlocked else { return nil }
            return hiddenBookmarks.count
        case .archive:
            return archivedBookmarks.count
        default:
            return nil
        }
    }

    private var hiddenBookmarkSortMenu: some View {
        sortMenu(selection: hiddenBookmarkListSortModeBinding)
    }

    private func sortMenu(selection: Binding<BookmarkListSortMode>) -> some View {
        CompactBorderedMenuPicker(
            options: Array(BookmarkListSortMode.allCases),
            selection: selection,
            title: { $0.title }
        )
    }

    private var llmModelSourcePicker: some View {
        CompactBorderedMenuPicker(
            options: Array(LLMModelSource.allCases),
            selection: llmModelSourceBinding,
            title: { $0.localizedTitle }
        )
    }

    private var llmModelSourceBinding: Binding<LLMModelSource> {
        Binding(
            get: { llmProfiles.activeSource },
            set: { newValue in
                var profiles = llmProfiles
                profiles.activeSource = newValue
                persistLLMConfig(profiles)
            }
        )
    }

    private var llmAPIKeyBinding: Binding<String> {
        llmConfigBinding(\.apiKey)
    }

    private var llmModelBinding: Binding<String> {
        llmConfigBinding(\.model)
    }

    private var llmBaseURLBinding: Binding<String> {
        llmConfigBinding(\.baseURL)
    }

    private func llmConfigBinding(_ keyPath: WritableKeyPath<LLMConfig, String>) -> Binding<String> {
        Binding(
            get: {
                switch llmProfiles.activeSource {
                case .remote: llmProfiles.remote[keyPath: keyPath]
                case .local: llmProfiles.local[keyPath: keyPath]
                }
            },
            set: { newValue in
                var profiles = llmProfiles
                switch profiles.activeSource {
                case .remote:
                    profiles.remote[keyPath: keyPath] = newValue
                case .local:
                    profiles.local[keyPath: keyPath] = newValue
                }
                persistLLMConfig(profiles)
            }
        )
    }

    @ViewBuilder
    private var settingsDetail: some View {
        NavigationStack {
            switch settingsPage {
            case .bookmarks:
                bookmarkManagementPage
            case .search:
                searchPage
            case .collections:
                collectionsManagementPage
            case .browserHistory:
                browserHistoryPage
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
                aiOptimizationPage
            case .cloudSync:
                CloudSyncSettingsView(cloudSync: cloudSync)
            case .privacy:
                privacyPage
            case .settings:
                appSettingsPage
            }
        }
        .navigationTitle(settingsPage.title)
    }

    private var bookmarkManagementPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.bookmarks.isEmpty {
                bookmarkDisplayModePicker
                    .padding(.leading, 0)
                    .padding(.trailing, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }

            if model.bookmarks.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("还没有书签")
                    } icon: {
                        Image(nsImage: AppIcon.image(size: NSSize(width: 28, height: 28)))
                    }
                } description: {
                    Text("点击工具栏的 + 添加你的第一个书签")
                }
            } else if bookmarkDisplayMode == .dateGrid, visibleBookmarks.isEmpty {
                ContentUnavailableView {
                    Label("没有可见书签", systemImage: "square.grid.2x2")
                } description: {
                    Text("隐藏书签和归档书签不会显示在这里")
                }
            } else if bookmarkDisplayMode == .dateGrid {
                BookmarkSectionGridView(
                    sections: dateGridBookmarkSections,
                    selection: $selection,
                    faviconLoader: faviconLoader,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: { bookmarks in openBookmarks(bookmarks) },
                    onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                    onRefreshFavicon: { bookmarks in refreshFavicons(for: bookmarks) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "移到隐藏书签".obeliskLocalized,
                    onSetHidden: { ids in requestHiddenFromContextMenu(ids: ids, isHidden: true) },
                    archiveStateActionTitle: "归档".obeliskLocalized,
                    onSetArchived: { ids in requestArchivedFromContextMenu(ids: ids, isArchived: true) },
                    onSetPinned: { ids in requestPinFromContextMenu(ids: ids) },
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: { bookmarkIds, collectionId in
                        requestAssignCollectionFromContextMenu(bookmarkIds: bookmarkIds, collectionId: collectionId)
                    },
                    onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                )
            } else if bookmarkSections.isEmpty {
                ContentUnavailableView {
                    Label("没有未分组的书签", systemImage: "bookmark")
                } description: {
                    Text("已放入分组的书签在「分组」页查看")
                }
            } else {
                NativeBookmarkList(
                    sections: bookmarkSections,
                    selection: $selection,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: { bookmarks in openBookmarks(bookmarks) },
                    onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                    onRefreshFavicon: { bookmarks in refreshFavicons(for: bookmarks) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "移到隐藏书签".obeliskLocalized,
                    onSetHidden: { ids in requestHiddenFromContextMenu(ids: ids, isHidden: true) },
                    archiveStateActionTitle: "归档".obeliskLocalized,
                    onSetArchived: { ids in requestArchivedFromContextMenu(ids: ids, isArchived: true) },
                    onSetPinned: { ids in requestPinFromContextMenu(ids: ids) },
                    onSortModeChange: { sortMode, scope in
                        updateBookmarkListSortMode(sortMode, scope: scope)
                    },
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: { bookmarkIds, collectionId in
                        requestAssignCollectionFromContextMenu(bookmarkIds: bookmarkIds, collectionId: collectionId)
                    },
                    onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                )
            }
        }
        .navigationTitle("书签")
    }

    private var bookmarkDisplayModePicker: some View {
        HStack(spacing: 10) {
            Picker("", selection: bookmarkDisplayModeBinding) {
                ForEach([BookmarkDisplayMode.dateGrid, .list]) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 154)

            Spacer(minLength: 0)
        }
    }

    private var hiddenBookmarkDisplayModePicker: some View {
        HStack(spacing: 10) {
            Picker("", selection: hiddenBookmarkDisplayModeBinding) {
                ForEach([BookmarkDisplayMode.dateGrid, .list]) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 154)

            Spacer(minLength: 0)
        }
    }

    private var collectionBookmarkDisplayModePicker: some View {
        HStack(spacing: 10) {
            Picker("", selection: collectionBookmarkDisplayModeBinding) {
                ForEach([BookmarkDisplayMode.dateGrid, .list]) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 154)

            Spacer(minLength: 0)
        }
    }

    private var searchPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeSearchField(
                text: $searchText,
                placeholder: "搜索",
                focusRequest: searchFocusRequest
            )
                .frame(height: 38)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            CompactBorderedMenuPicker(
                options: searchFilterOptions,
                selection: searchFilterBinding,
                title: { searchFilterTitle(for: $0) }
            )
            .padding(.leading, 16)
            .padding(.bottom, 6)

            if searchBookmarkSections.isEmpty {
                ContentUnavailableView {
                    Label("没有结果", systemImage: "magnifyingglass")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeBookmarkList(
                    sections: searchBookmarkSections,
                    selection: $selection,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: { bookmarks in openBookmarks(bookmarks) },
                    onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                    onRefreshFavicon: { bookmarks in refreshFavicons(for: bookmarks) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "移到隐藏书签".obeliskLocalized,
                    onSetHidden: { ids in requestHiddenFromContextMenu(ids: ids, isHidden: true) },
                    archiveStateActionTitleProvider: { bookmarks in
                        let shouldArchive = bookmarks.isEmpty || !bookmarks.allSatisfy { model.isEffectivelyArchived($0) }
                        return shouldArchive ? "归档".obeliskLocalized : "恢复到书签".obeliskLocalized
                    },
                    onSetArchived: { ids in
                        let bookmarks = model.bookmarks.filter { ids.contains($0.id) }
                        let shouldArchive = bookmarks.isEmpty || !bookmarks.allSatisfy { model.isEffectivelyArchived($0) }
                        requestArchivedFromContextMenu(ids: ids, isArchived: shouldArchive)
                    },
                    onSetPinned: { ids in requestPinFromContextMenu(ids: ids) },
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: { bookmarkIds, collectionId in
                        requestAssignCollectionFromContextMenu(bookmarkIds: bookmarkIds, collectionId: collectionId)
                    },
                    onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                )
            }
        }
        .navigationTitle("搜索")
    }

    private var collectionsManagementPage: some View {
        VStack(spacing: 0) {
            if !model.collections.isEmpty {
                collectionBookmarkDisplayModePicker
                    .padding(.leading, 0)
                    .padding(.trailing, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }

            if model.collections.isEmpty {
                ContentUnavailableView {
                    Label("还没有分组", systemImage: "folder")
                } description: {
                    Text("点击工具栏 + 创建分组")
                }
            } else if collectionBookmarkDisplayMode == .dateGrid {
                BookmarkSectionGridView(
                    sections: collectionGridSections,
                    selection: $selection,
                    selectedCollectionId: $selectedCollectionId,
                    faviconLoader: faviconLoader,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: { bookmarks in openBookmarks(bookmarks) },
                    onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                    onRefreshFavicon: { bookmarks in refreshFavicons(for: bookmarks) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "移到隐藏书签".obeliskLocalized,
                    onSetHidden: { ids in requestHiddenFromContextMenu(ids: ids, isHidden: true) },
                    archiveStateActionTitle: "归档".obeliskLocalized,
                    onSetArchived: { ids in requestArchivedFromContextMenu(ids: ids, isArchived: true) },
                    onSetPinned: { ids in requestPinFromContextMenu(ids: ids) },
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: { bookmarkIds, collectionId in
                        requestAssignCollectionFromContextMenu(bookmarkIds: bookmarkIds, collectionId: collectionId)
                    },
                    onRenameCollection: { id in beginRenameCollection(id: id) },
                    onDeleteCollection: { id in beginDeleteCollection(id: id) },
                    onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                )
            } else if collectionBookmarkSections.allSatisfy({ $0.bookmarks.isEmpty }) {
                NativeBookmarkList(
                    sections: collectionBookmarkSections,
                    selection: $selection,
                    selectedCollectionId: $selectedCollectionId,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onSortModeChange: { sortMode, _ in collectionListSortMode = sortMode },
                    onRenameCollection: { id in beginRenameCollection(id: id) },
                    onDeleteCollection: { id in beginDeleteCollection(id: id) },
                    onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                )
            } else {
                NativeBookmarkList(
                    sections: collectionBookmarkSections,
                    selection: $selection,
                    selectedCollectionId: $selectedCollectionId,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: { bookmarks in openBookmarks(bookmarks) },
                    onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                    onRefreshFavicon: { bookmarks in refreshFavicons(for: bookmarks) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "移到隐藏书签".obeliskLocalized,
                    onSetHidden: { ids in requestHiddenFromContextMenu(ids: ids, isHidden: true) },
                    archiveStateActionTitle: "归档".obeliskLocalized,
                    onSetArchived: { ids in requestArchivedFromContextMenu(ids: ids, isArchived: true) },
                    onSetPinned: { ids in requestPinFromContextMenu(ids: ids) },
                    onSortModeChange: { sortMode, _ in collectionListSortMode = sortMode },
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: { bookmarkIds, collectionId in
                        requestAssignCollectionFromContextMenu(bookmarkIds: bookmarkIds, collectionId: collectionId)
                    },
                    onRenameCollection: { id in beginRenameCollection(id: id) },
                    onDeleteCollection: { id in beginDeleteCollection(id: id) },
                    onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                )
            }
        }
        .navigationTitle("分组")
    }

    private var browserHistoryPage: some View {
        BookmarkBrowserHistoryPage(
            model: model,
            faviconLoader: faviconLoader,
            showsURLHostOnly: showsURLHostOnly
        )
    }

    private var hiddenBookmarkManagementPage: some View {
        Group {
            if hiddenBookmarks.isEmpty {
                ContentUnavailableView {
                    Label("还没有隐藏书签", systemImage: "eye.slash")
                } description: {
                    Text("按 ⌥H 可以把当前浏览器标签添加为隐藏书签")
                }
            } else if hiddenBookmarkDisplayMode == .dateGrid {
                VStack(spacing: 0) {
                    hiddenBookmarkDisplayModePicker
                        .padding(.leading, 0)
                        .padding(.trailing, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    BookmarkSectionGridView(
                        sections: hiddenBookmarkDateGridSections,
                        selection: $selection,
                        faviconLoader: faviconLoader,
                        showsURLHostOnly: showsURLHostOnly,
                        onOpen: { bookmarks in openHiddenBookmarks(bookmarks) },
                        onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                        onRefreshFavicon: { bookmarks in refreshFavicons(for: bookmarks) },
                        onEdit: { bookmark in presentation = .edit(bookmark) },
                        onDelete: { ids in requestDelete(ids: ids) },
                        hiddenStateActionTitle: "恢复到书签".obeliskLocalized,
                        onSetHidden: { ids in requestHiddenFromContextMenu(ids: ids, isHidden: false) },
                        archiveStateActionTitle: "归档".obeliskLocalized,
                        onSetArchived: { ids in requestArchivedFromContextMenu(ids: ids, isArchived: true) },
                        onSetPinned: { ids in requestPinFromContextMenu(ids: ids) },
                        collectionAssignOptions: collectionAssignOptions,
                        onAssignCollection: { bookmarkIds, collectionId in
                            requestAssignCollectionFromContextMenu(bookmarkIds: bookmarkIds, collectionId: collectionId)
                        },
                        onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    hiddenBookmarkDisplayModePicker
                        .padding(.leading, 0)
                        .padding(.trailing, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    hiddenBookmarkSortMenu
                        .padding(.leading, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    NativeBookmarkList(
                        sections: hiddenBookmarkSections,
                        selection: $selection,
                        faviconLoader: faviconLoader,
                        faviconVersion: faviconLoader.version,
                        showsURLHostOnly: showsURLHostOnly,
                        onOpen: { bookmarks in openHiddenBookmarks(bookmarks) },
                        onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                        onRefreshFavicon: { bookmarks in refreshFavicons(for: bookmarks) },
                        onEdit: { bookmark in presentation = .edit(bookmark) },
                        onDelete: { ids in requestDelete(ids: ids) },
                        hiddenStateActionTitle: "恢复到书签".obeliskLocalized,
                        onSetHidden: { ids in requestHiddenFromContextMenu(ids: ids, isHidden: false) },
                        onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                    )
                }
            }
        }
        .navigationTitle("隐藏书签")
    }

    private var archivePage: some View {
        VStack(spacing: 0) {
            Form {
                Section("自动归档") {
                    Toggle(
                        isOn: Binding(
                            get: { autoArchiveEnabled },
                            set: { newValue in
                                autoArchiveEnabled = newValue
                                syncArchiveSettings()
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动归档闲置书签")
                            Text("开启后 Obelisk 会自动归档您一段时间没有使用的书签")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if autoArchiveEnabled {
                        LabeledContent {
                            HStack(spacing: 10) {
                                Text("\(archiveAfterDays)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 24, alignment: .trailing)

                                Stepper(
                                    "闲置天数",
                                    value: Binding(
                                        get: { archiveAfterDays },
                                        set: { newValue in
                                            archiveAfterDays = BookmarksModel.clampedArchiveAfterDays(newValue)
                                            syncArchiveSettings()
                                        }
                                    ),
                                    in: BookmarksModel.minArchiveAfterDays...BookmarksModel.maxArchiveAfterDays
                                )
                                .labelsHidden()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("闲置天数")
                                Text("Obelisk 会自动将超过这个天数没有打开的书签归档")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
            .settingsContentMargins()
            .frame(height: 190)

            if archivedBookmarks.isEmpty {
                ContentUnavailableView {
                    Label("没有归档书签", systemImage: "archivebox")
                } description: {
                    if autoArchiveEnabled {
                        Text("闲置书签会在达到设定天数后自动归档")
                    } else {
                        Text("您手动归档的书签会显示在这里")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeBookmarkList(
                    sections: archivedBookmarkSections,
                    selection: $selection,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: { bookmarks in openArchivedBookmarks(bookmarks) },
                    onCopyURL: { bookmarks in copyURLs(of: bookmarks) },
                    onRefreshFavicon: { bookmarks in refreshFavicons(for: bookmarks) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    archiveStateActionTitle: "恢复到书签".obeliskLocalized,
                    onSetArchived: { ids in requestArchivedFromContextMenu(ids: ids, isArchived: false) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("归档")
    }

    private var appearancePage: some View {
        Form {
            Section("侧边栏") {
                LabeledContent("主题") {
                    Picker("主题", selection: sidebarIconThemeBinding) {
                        ForEach(SidebarIconTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                LabeledContent("图标风格") {
                    Picker("图标风格", selection: sidebarIconStyleBinding) {
                        ForEach(SidebarIconStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Section("窗口") {
                Toggle(isOn: $windowTransparencyEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("启用窗口透明效果")
                        Text("为 Obelisk 窗口启用毛玻璃半透明材质")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if windowTransparencyEnabled {
                    Toggle(isOn: customTransparencyBinding) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自定义透明度")
                            Text("开启后可手动调整窗口透明度")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if customTransparencyEnabled {
                        Slider(value: $windowSeeThrough, in: 0...0.5, step: 0.05) {
                            Text("透明度")
                        } minimumValueLabel: {
                            Text("0%")
                        } maximumValueLabel: {
                            Text("50%")
                        }

                        LabeledContent("当前透明度", value: "\(Int(windowSeeThrough * 100))%")
                    }
                }
            }

            Section("域名显示") {
                Toggle(isOn: showsFullURLBinding) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("显示完整网站域名")
                        Text("开启后书签列表会显示完整 URL")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("菜单栏") {
                LabeledContent("图标样式") {
                    Picker("图标样式", selection: menuBarIconStyleBinding) {
                        ForEach(MenuBarIconStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                menuLimitStepper("最近添加数量", desc: "「最近添加」最多显示的书签数量", value: $menuRecentGroupLimit)
                menuLimitStepper("最近浏览数量", desc: "「最近浏览」最多显示的网页数量", value: $menuBrowserHistoryLimit)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("外观")
    }

    private var menuBarPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("菜单栏排序")
                    .font(.headline)
                    .foregroundStyle(.primary)

                menuBarOrderCard
            }
            .padding(.top, 20)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .onDisappear(perform: resetMenuBarOrderDrag)
        .navigationTitle("菜单栏")
    }

    @ViewBuilder
    private var menuBarOrderCard: some View {
        if #available(macOS 27.0, *) {
            nativeMenuBarOrderCard
        } else {
            legacyMenuBarOrderCard
        }
    }

    @available(macOS 27.0, *)
    private var nativeMenuBarOrderCard: some View {
        let items = menuBarOrderItems

        return VStack(spacing: 0) {
            ForEach(items) { item in
                menuBarOrderRow(for: item, isPlaceholder: false, isDropTarget: false)
                    .overlay(alignment: .bottom) {
                        if item.id != items.last?.id {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
            }
            .reorderable()
        }
        .reorderContainer(for: BookmarkMenuOrderItem.self, itemID: \.id) { difference in
            moveMenuBarSections(using: difference)
        }
        .frame(height: CGFloat(items.count) * menuBarOrderRowHeight)
        .background {
            menuBarOrderBackground(cornerRadius: 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var legacyMenuBarOrderCard: some View {
        let items = menuBarOrderItems

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    menuBarOrderRow(
                        for: item,
                        isPlaceholder: draggingMenuBarSectionID == item.id,
                        isDropTarget: menuBarDragTargetIndex == index && draggingMenuBarSectionID != item.id
                    )
                    .overlay(alignment: .bottom) {
                        if index < items.count - 1 {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                    .offset(y: menuBarOrderRowOffset(for: index, itemID: item.id))
                    .animation(.easeInOut(duration: 0.12), value: menuBarDragTargetIndex)
                    .gesture(menuBarOrderDragGesture(for: item, at: index, itemCount: items.count))
                }
            }

            if let draggingMenuBarSectionID,
               let startIndex = menuBarDragStartIndex,
               let item = items.first(where: { $0.id == draggingMenuBarSectionID }) {
                menuBarOrderRow(for: item, isPlaceholder: false, isDropTarget: false)
                    .background {
                        menuBarOrderBackground(cornerRadius: 9)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .offset(y: CGFloat(startIndex) * menuBarOrderRowHeight + menuBarDragOffsetY)
                    .zIndex(2)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: CGFloat(items.count) * menuBarOrderRowHeight)
        .background {
            menuBarOrderBackground(cornerRadius: 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeInOut(duration: 0.12), value: items.map(\.id))
    }

    @ViewBuilder
    private func menuBarOrderBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if windowTransparencyEnabled {
            shape.fill(menuBarOrderTransparentBackgroundColor)
        } else {
            shape.fill(menuBarOrderBackgroundColor)
        }
    }

    private func menuBarOrderRow(
        for item: BookmarkMenuOrderItem,
        isPlaceholder: Bool,
        isDropTarget: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Text(item.title)
                .lineLimit(1)
                .foregroundStyle(.primary)

            Spacer(minLength: 16)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: menuBarOrderRowHeight)
        .contentShape(Rectangle())
        .opacity(isPlaceholder ? 0 : 1)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 0, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            }
        }
        .accessibilityLabel(item.title)
    }

    private func menuBarOrderDragGesture(
        for item: BookmarkMenuOrderItem,
        at index: Int,
        itemCount: Int
    ) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if draggingMenuBarSectionID != item.id {
                    draggingMenuBarSectionID = item.id
                    menuBarDragStartIndex = index
                    menuBarDragTargetIndex = index
                    menuBarDragOffsetY = 0
                }

                guard draggingMenuBarSectionID == item.id else { return }
                let startIndex = menuBarDragStartIndex ?? index
                let targetIndex = stableMenuBarOrderTargetIndex(
                    startIndex: startIndex,
                    translationY: value.translation.height,
                    itemCount: itemCount
                )
                menuBarDragOffsetY = value.translation.height

                if menuBarDragTargetIndex != targetIndex {
                    menuBarDragTargetIndex = targetIndex
                }
            }
            .onEnded { value in
                defer { resetMenuBarOrderDrag() }
                guard draggingMenuBarSectionID == item.id else { return }
                let targetIndex = menuBarDragTargetIndex ?? menuBarOrderTargetIndex(
                    startIndex: menuBarDragStartIndex ?? index,
                    translationY: value.translation.height,
                    itemCount: itemCount
                )
                moveMenuBarSection(draggedID: item.id, toIndex: targetIndex)
            }
    }

    private var shortcutsPage: some View {
        Form {
            Section("快捷键") {
                ShortcutRecorderRow(title: "添加书签", name: .addBookmark)
                ShortcutRecorderRow(title: "添加隐藏书签", name: .addHiddenBookmark)
                ShortcutRecorderRow(title: "快速搜索", name: .quickSearch)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("快捷键")
    }

    private func menuLimitStepper(
        _ title: LocalizedStringKey,
        desc: LocalizedStringKey? = nil,
        value: Binding<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                HStack(spacing: 10) {
                    Text("\(value.wrappedValue)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 24, alignment: .trailing)

                    Stepper(title, value: value, in: 0...20)
                        .labelsHidden()
                }
            }

            if let desc {
                Text(desc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var aiOptimizationPage: some View {
        Form {
            Section("Intelligence 功能") {
                Toggle("开启 Intelligence 功能", isOn: $aiFeaturesEnabled)
            }

            if aiFeaturesEnabled {
                Section("Intelligence 书签优化") {
                    Toggle(isOn: $autoOptimizeNewBookmarks) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动优化新书签标题")
                            Text("开启后将自动使用配置的模型优化新添加的书签标题")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $autoGroupNewBookmarks) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动分组新书签")
                            Text("开启后将自动使用配置的模型把新添加的可见书签归入合适分组")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("优化隐藏书签", isOn: $optimizeHiddenBookmarks)

                    Toggle("自动翻译非中文标题", isOn: $translateNonChineseTitles)
                }

                Section("模型配置") {
                    LabeledContent {
                        llmModelSourcePicker
                    } label: {
                        Text("模型来源")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(
                            text: llmAPIKeyBinding,
                            prompt: Text(llmProfiles.activeSource == .remote ? "sk-…" : "lm-studio")
                        ) {
                            Label("API Key", systemImage: "key")
                        }
                        Text(
                            llmProfiles.activeSource == .remote
                                ? "用于访问云端 OpenAI 兼容服务的 API Key"
                                : "本地服务通常不校验 Key，填任意非空字符串即可"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            text: llmModelBinding,
                            prompt: Text(llmProfiles.activeSource == .remote ? "gpt-4.1-mini" : "qwen3.5-4b")
                        ) {
                            Label("Model", systemImage: "cpu")
                        }
                        Text(
                            llmProfiles.activeSource == .remote
                                ? "远程服务的模型名称，如 gpt-4.1-mini"
                                : "须与 LM Studio Local Server 里已加载模型的 id 一致"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            text: llmBaseURLBinding,
                            prompt: Text(
                                llmProfiles.activeSource == .remote
                                    ? "https://api.openai.com/v1/chat/completions"
                                    : "http://localhost:1234/v1/chat/completions"
                            )
                        ) {
                            Label("Base URL", systemImage: "link")
                        }
                        Text(
                            llmProfiles.activeSource == .remote
                                ? "远程 API 的 chat completions 地址"
                                : "须先在本机启动 LM Studio Local Server（默认端口 1234）"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button {
                            testLLMConfig()
                        } label: {
                            Text(isTestingLLMConfig ? "测试中…" : "测试模型连接")
                        }
                        .disabled(isTestingLLMConfig)

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("Intelligence")
    }

    private var appSettingsPage: some View {
        Form {
            Section("启动") {
                Toggle("在登录时启动 Obelisk", isOn: launchAtLoginBinding)
            }

            Section("语言") {
                LabeledContent("语言") {
                    CompactBorderedMenuPicker(
                        options: Array(AppLanguagePreference.allCases),
                        selection: appLanguagePreferenceBinding,
                        title: { $0.pickerLabel }
                    )
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("设置")
        .onAppear {
            refreshLaunchAtLoginState()
        }
    }

    private var appLanguagePreferenceBinding: Binding<AppLanguagePreference> {
        Binding(
            get: { AppLanguagePreference(rawValue: appLanguagePreferenceRaw) ?? .auto },
            set: { newValue in
                let current = AppLanguagePreference(rawValue: appLanguagePreferenceRaw) ?? .auto
                guard newValue != current else { return }
                appLanguagePreferenceRaw = newValue.rawValue
                AppLanguagePreference.persistForNextLaunch(newValue)
                showLanguageRestartAlert = true
            }
        )
    }

    private var privacyPage: some View {
        Form {
            Section("隐藏书签") {
                Toggle("在侧边栏显示隐藏书签", isOn: $showHiddenBookmarksPage)

                Toggle(isOn: $openHiddenBookmarksIncognito) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("使用无痕窗口打开隐藏书签")
                        Text("Dia 会复用 Obelisk 创建的无痕窗口；其他 Chromium 浏览器使用启动参数")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("排除关键词")

                    HStack(spacing: 8) {
                        TextField("", text: $newHiddenBookmarkExcludedURLKeyword)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addHiddenBookmarkExcludedURLKeyword)

                        Button {
                            addHiddenBookmarkExcludedURLKeyword()
                        } label: {
                            Text("添加")
                        }
                        .disabled(newHiddenBookmarkExcludedURLKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    ForEach(hiddenBookmarkExcludedURLKeywords, id: \.self) { keyword in
                        HStack(spacing: 8) {
                            Text(keyword)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 0)

                            Button(role: .destructive) {
                                removeHiddenBookmarkExcludedURLKeyword(keyword)
                            } label: {
                                Label("删除", systemImage: "minus.circle")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                        }
                    }

                    Text("包含关键字的 URL 只能添加到「隐藏书签」")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("隐私")
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        if settingsPage == .bookmarks {
            ToolbarItemGroup {
                if !model.collections.isEmpty {
                    Menu {
                        ForEach(model.collections) { collection in
                            Button(collection.name) {
                                assignCollectionToSelection(collectionId: collection.id)
                            }
                        }
                        Button("未分组") {
                            assignCollectionToSelection(collectionId: nil)
                        }
                    } label: {
                        Label("移到分组", systemImage: "folder")
                    }
                    .disabled(selection.isEmpty)
                    .help("将选中的书签移到分组")
                }

                Button {
                    presentation = .add(seq: 0, prefilledURL: nil, prefilledTitle: nil, prefilledIsHidden: false)
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .disabled(selection.count > 1)
                .help("添加书签")

                Button {
                    if let bookmark = selectedBookmark {
                        presentation = .edit(bookmark)
                    }
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .disabled(!canUseSingleSelectionActions)

                Button {
                    togglePinnedSelection()
                } label: {
                    Label(selectedPinnedTargetState ? "置顶" : "取消置顶", systemImage: selectedPinnedSystemImage)
                }
                .disabled(!canTogglePinnedSelection)
                .help(selectedPinnedTargetState ? "置顶选中的书签" : "取消置顶选中的书签")
            }

            ToolbarItem {
                Button(role: .destructive) {
                    requestDelete(ids: selection)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(!canDeleteSelection)
                .help("删除选中的书签")
                .foregroundStyle(.red)
                .tint(.red)
            }

            if aiFeaturesEnabled {
                ToolbarSpacer(.fixed)

                ToolbarItem {
                    Button {
                        optimizeBookmarks(includeAutoGrouping: true)
                    } label: {
                        IntelligenceSymbolLabel(
                            title: model.isOptimizingBookmarks ? "优化中" : "书签优化"
                        )
                    }
                    .disabled(
                        model.isOptimizingBookmarks
                            || (optimizableTitleCountInScope == 0 && autoGroupableBookmarkCountInScope == 0)
                    )
                    .help(
                        selection.isEmpty
                            ? "优化全部可用书签的标题与分组"
                            : "优化选中书签的标题与分组"
                    )
                }
            }
        } else if settingsPage == .collections {
            ToolbarItemGroup {
                if !model.collections.isEmpty {
                    Menu {
                        ForEach(model.collections) { collection in
                            Button(collection.name) {
                                assignCollectionToSelection(collectionId: collection.id)
                            }
                        }
                        Button("未分组") {
                            assignCollectionToSelection(collectionId: nil)
                        }
                    } label: {
                        Label("移到分组", systemImage: "folder")
                    }
                    .disabled(selection.isEmpty)
                    .help("将选中的书签移到其他分组")
                }

                Button {
                    newCollectionName = ""
                    showNewCollectionDialog = true
                } label: {
                    Label("新建", systemImage: "plus")
                }
                .help("新建分组")

                Button {
                    requestEditCollectionPageSelection()
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                .disabled(!canEditCollectionPageSelection)
                .help("重命名选中的分组")

                Button {
                    togglePinnedSelection()
                } label: {
                    Label(selectedPinnedTargetState ? "置顶" : "取消置顶", systemImage: selectedPinnedSystemImage)
                }
                .disabled(!canTogglePinnedSelection)
                .help(selectedPinnedTargetState ? "置顶选中的书签" : "取消置顶选中的书签")
            }

            ToolbarItem {
                Button(role: .destructive) {
                    requestDeleteCollectionPageSelection()
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(!canDeleteCollectionPageSelection)
                .help("删除选中的分组")
                .foregroundStyle(.red)
                .tint(.red)
            }

            if aiFeaturesEnabled {
                ToolbarSpacer(.fixed)

                ToolbarItem {
                    Button {
                        optimizeBookmarks(includeAutoGrouping: true)
                    } label: {
                        IntelligenceSymbolLabel(
                            title: model.isOptimizingBookmarks ? "优化中" : "书签优化"
                        )
                    }
                    .disabled(
                        model.isOptimizingBookmarks
                            || (optimizableTitleCountInScope == 0 && autoGroupableBookmarkCountInScope == 0)
                    )
                    .help(
                        selection.isEmpty
                            ? "优化全部可用书签的标题与分组"
                            : "优化选中书签的标题与分组"
                    )
                }
            }
        } else if settingsPage == .hiddenBookmarks {
            ToolbarItemGroup {
                Button {
                    presentation = .add(seq: 0, prefilledURL: nil, prefilledTitle: nil, prefilledIsHidden: true)
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .disabled(selection.count > 1)
                .help("添加隐藏书签")

                Button {
                    if let bookmark = selectedBookmark {
                        presentation = .edit(bookmark)
                    }
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .disabled(!canUseSingleSelectionActions)
            }

            ToolbarItem {
                Button(role: .destructive) {
                    requestDelete(ids: selection)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(!canDeleteSelection)
                .help("删除选中的隐藏书签")
                .foregroundStyle(.red)
                .tint(.red)
            }

            if aiFeaturesEnabled, optimizeHiddenBookmarks {
                ToolbarSpacer(.fixed)

                ToolbarItem {
                    Button {
                        optimizeBookmarks(includeAutoGrouping: false)
                    } label: {
                        IntelligenceSymbolLabel(
                            title: model.isOptimizingBookmarks ? "优化中" : "书签优化"
                        )
                    }
                    .disabled(
                        selection.isEmpty
                            || model.isOptimizingBookmarks
                            || optimizableTitleCountInScope == 0
                    )
                    .help("优化选中隐藏书签的标题")
                }
            }
        }
    }
}
