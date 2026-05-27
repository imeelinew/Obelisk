import AppKit
import SwiftUI

enum BookmarkListSortMode: String, CaseIterable, Identifiable {
    case name
    case recentlyAdded
    case frequency

    static let bookmarksStorageKey = "bookmarkListSortMode"
    static let collectionsStorageKey = "bookmarkCollectionListSortMode"
    static let hiddenStorageKey = "hiddenBookmarkListSortMode"
    static let storageKey = bookmarksStorageKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "按名称"
        case .recentlyAdded: return "按最近添加"
        case .frequency: return "按使用频率"
        }
    }

    static var stored: BookmarkListSortMode { storedForBookmarks }
    static var storedForBookmarks: BookmarkListSortMode { stored(for: bookmarksStorageKey) }
    static var storedForCollections: BookmarkListSortMode { stored(for: collectionsStorageKey) }
    static var storedForHiddenBookmarks: BookmarkListSortMode { stored(for: hiddenStorageKey) }

    func sorted(
        _ bookmarks: [Bookmark],
        usage: [UUID: UsageRecord] = [:],
        now: Date = Date()
    ) -> [Bookmark] {
        switch self {
        case .name:
            return bookmarks.sorted { lhs, rhs in
                Self.isOrderedByName(lhs, before: rhs)
            }
        case .recentlyAdded:
            return bookmarks.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return Self.isOrderedByName(lhs, before: rhs)
            }
        case .frequency:
            return UsageStore.frecencySorted(among: bookmarks, usage: usage, now: now)
        }
    }

    private static func isOrderedByName(_ lhs: Bookmark, before rhs: Bookmark) -> Bool {
        let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }

        let urlComparison = lhs.url.localizedStandardCompare(rhs.url)
        if urlComparison != .orderedSame {
            return urlComparison == .orderedAscending
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func stored(for key: String) -> BookmarkListSortMode {
        BookmarkListSortMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .name
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
    @Bindable var model: BookmarksModel
    let faviconLoader: FaviconLoader
    let addRequest: AddBookmarkRequest
    let onStorageRootChanged: (URL) -> Void
    @State private var selection: Set<Bookmark.ID> = []
    @State private var presentation: Presentation?
    @State private var deleteConfirmation: DeleteConfirmation?
    @State private var refreshAllFaviconConfirmation = false
    @State private var toast: Toast?
    @State private var searchText = ""
    @State private var settingsPage: SettingsPage = .bookmarks
    @State private var selectedCollectionId: UUID?
    @State private var llmProfiles = LLMProfilesSettings()
    @State private var llmConfigMessage: String?
    @State private var isTestingLLMConfig = false
    @State private var hiddenBookmarksUnlocked = false
    @AppStorage("debugSidebarIconTileSize") private var sidebarIconTileSize: Double = 22
    @AppStorage("debugSidebarIconSymbolSize") private var sidebarIconSymbolSize: Double = 11
    @AppStorage("debugSidebarIconCornerRadius") private var sidebarIconCornerRadius: Double = 6
    @AppStorage("showHiddenBookmarksPage") private var showHiddenBookmarksPage = false
    @AppStorage("showsURLHostOnly") private var showsURLHostOnly = false
    @AppStorage("menuRecentGroupLimit") private var menuRecentGroupLimit = 5
    @AppStorage(BookmarksModel.autoArchiveEnabledKey) private var autoArchiveEnabled = false
    @AppStorage(BookmarksModel.archiveAfterDaysKey) private var archiveAfterDays = BookmarksModel.defaultArchiveAfterDays
    @AppStorage("windowTransparencyEnabled") private var windowTransparencyEnabled = false
    @AppStorage(LocalJSONEncryption.enabledKey) private var encryptLocalJSONData = false
    @AppStorage("openHiddenBookmarksIncognito") private var openHiddenBookmarksIncognito = false
    @AppStorage("silentAddEnabled") private var silentAddEnabled = false
    @AppStorage("autoOptimizeNewBookmarks") private var autoOptimizeNewBookmarks = false
    @AppStorage(BookmarksModel.aiFeaturesEnabledKey) private var aiFeaturesEnabled = true
    @AppStorage(TitleOptimizationIntensity.storageKey) private var titleOptimizationIntensityRaw = TitleOptimizationIntensity.standard.rawValue
    @AppStorage(TitleOptimizationTranslation.storageKey) private var translateNonChineseTitles = false
    @AppStorage(BookmarkListSortMode.bookmarksStorageKey) private var bookmarkListSortModeRaw = BookmarkListSortMode.name.rawValue
    @AppStorage(BookmarkListSortMode.collectionsStorageKey) private var collectionListSortModeRaw = BookmarkListSortMode.name.rawValue
    @AppStorage(BookmarkListSortMode.hiddenStorageKey) private var hiddenBookmarkListSortModeRaw = BookmarkListSortMode.name.rawValue
    @AppStorage(BookmarkMenuSectionOrder.storageKey) private var menuBarSectionOrderRaw = ""
    // 0 = 完全不透明（默认毛玻璃材质满强度）；上限 0.5（再透可读性会崩）。
    @AppStorage("windowSeeThrough") private var windowSeeThrough: Double = 0.0
    @AppStorage("customTransparencyEnabled") private var customTransparencyEnabled = false
    @State private var showCustomTransparencyAlert = false
    @State private var showNewCollectionDialog = false
    @State private var newCollectionName = ""
    @State private var collectionToRename: BookmarkCollection?
    @State private var renameCollectionName = ""
    @State private var collectionToDelete: BookmarkCollection?
    @State private var isFetchingOriginalTitles = false
    @State private var isCreatingPlaintextBackup = false
    @State private var restoreAllOriginalTitlesConfirmation = false
    @State private var refetchAllOriginalTitlesConfirmation = false
    @AppStorage(BookmarksModel.developerFeaturesEnabledKey) private var developerFeaturesEnabled = false
    @State private var enableDeveloperFeaturesConfirmation = false
    @State private var resetDeveloperOptionsConfirmation = false
    @State private var draggingMenuBarSectionID: BookmarkMenuSectionID?
    @State private var menuBarDragStartIndex: Int?
    @State private var menuBarDragTargetIndex: Int?
    @State private var menuBarDragOffsetY: CGFloat = 0
    @State private var lastMenuBarOrderHapticDate = Date.distantPast

    private let menuBarOrderRowHeight: CGFloat = 50
    private let menuBarOrderCardBackgroundColor = Color(red: 233.0 / 255.0, green: 235.0 / 255.0, blue: 236.0 / 255.0)

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

    enum SettingsPage: String, CaseIterable, Hashable, Identifiable {
        case bookmarks
        case collections
        case hiddenBookmarks
        case archive
        case appearance
        case menuBar
        case shortcuts
        case ai
        case privacy
        case developer

        var id: String { rawValue }

        enum Group: String, CaseIterable, Identifiable {
            case content = "内容"
            case preferences = "偏好"
            case advanced = "高级"

            var id: String { rawValue }
        }

        var group: Group {
            switch self {
            case .bookmarks, .collections, .hiddenBookmarks, .archive: return .content
            case .appearance, .menuBar, .shortcuts:     return .preferences
            case .ai, .privacy, .developer:             return .advanced
            }
        }

        var title: String {
            switch self {
            case .bookmarks:       return "书签"
            case .collections:     return "分组"
            case .hiddenBookmarks: return "隐藏书签"
            case .archive:         return "归档"
            case .appearance:      return "外观"
            case .menuBar:         return "菜单栏"
            case .shortcuts:       return "快捷键"
            case .ai:              return "Intelligence"
            case .privacy:         return "隐私"
            case .developer:       return "开发者选项"
            }
        }

        var symbolName: String {
            switch self {
            case .bookmarks:       return "bookmark.fill"
            case .collections:     return "folder.fill"
            case .hiddenBookmarks: return "eye.slash.fill"
            case .archive:         return "archivebox.fill"
            case .appearance:      return "paintpalette.fill"
            case .menuBar:         return "menubar.rectangle"
            case .shortcuts:       return "command"
            case .ai:              return "apple.intelligence"
            case .privacy:         return "lock.fill"
            case .developer:       return "wrench.fill"
            }
        }

        var iconGradient: LinearGradient {
            switch self {
            case .bookmarks:
                return LinearGradient(
                    colors: [Color(red: 1.0, green: 0.50, blue: 0.40), Color(red: 0.96, green: 0.28, blue: 0.24)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .ai:
                return LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.78, blue: 0.25),
                        Color(red: 1.0, green: 0.20, blue: 0.28),
                        Color(red: 0.54, green: 0.28, blue: 0.96),
                        Color(red: 0.22, green: 0.66, blue: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .collections:
                return LinearGradient(
                    colors: [Color(red: 0.52, green: 0.72, blue: 0.98), Color(red: 0.22, green: 0.48, blue: 0.88)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .hiddenBookmarks:
                return LinearGradient(
                    colors: [Color(red: 0.58, green: 0.66, blue: 0.80), Color(red: 0.34, green: 0.44, blue: 0.62)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .archive:
                return LinearGradient(
                    colors: [Color(red: 0.66, green: 0.72, blue: 0.80), Color(red: 0.38, green: 0.46, blue: 0.56)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .appearance:
                return LinearGradient(
                    colors: [Color(red: 0.46, green: 0.82, blue: 0.50), Color(red: 0.14, green: 0.62, blue: 0.30)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .menuBar:
                return LinearGradient(
                    colors: [Color(red: 0.30, green: 0.78, blue: 0.90), Color(red: 0.12, green: 0.48, blue: 0.82)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .shortcuts:
                return LinearGradient(
                    colors: [Color(red: 0.98, green: 0.72, blue: 0.36), Color(red: 0.86, green: 0.48, blue: 0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .privacy:
                return LinearGradient(
                    colors: [Color(red: 0.72, green: 0.52, blue: 1.0), Color(red: 0.42, green: 0.24, blue: 0.86)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .developer:
                return LinearGradient(
                    colors: [Color(red: 1.0, green: 0.78, blue: 0.30), Color(red: 0.92, green: 0.52, blue: 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
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

    private var visibleBookmarks: [Bookmark] {
        model.bookmarks.filter { !$0.isHidden && !isEffectivelyArchived($0) }
    }

    private var hiddenBookmarks: [Bookmark] {
        model.bookmarks.filter { $0.isHidden && !isEffectivelyArchived($0) }
    }

    private var filteredHiddenBookmarks: [Bookmark] {
        model.sortedBookmarks(filtered(hiddenBookmarks), sortMode: hiddenBookmarkListSortMode)
    }

    private var archivedBookmarks: [Bookmark] {
        guard autoArchiveEnabled else { return [] }
        return model.bookmarks.filter { !$0.isHidden && model.isEffectivelyArchived($0) }
    }

    private var bookmarkSections: [BookmarkListSection] {
        let pinnedSections = model.pinnedSections(
            searchText: searchText,
            sortMode: bookmarkListSortMode,
            showsSortControl: true
        )
        let ungroupedSections = model.visibleUngroupedSections(
            searchText: searchText,
            sortMode: bookmarkListSortMode,
            showsSortControl: pinnedSections.isEmpty
        )
        return pinnedSections + ungroupedSections
    }

    private var collectionBookmarkSections: [BookmarkListSection] {
        model.visibleCollectionSections(
            searchText: searchText,
            sortMode: collectionListSortMode,
            includeEmptyCollections: true,
            showsSortControlOnFirstSection: true
        )
    }

    private var collectionAssignOptions: [BookmarkCollectionAssignOption] {
        var options = model.collections.map {
            BookmarkCollectionAssignOption(title: $0.name, collectionId: $0.id)
        }
        options.append(BookmarkCollectionAssignOption(title: "未分组", collectionId: nil))
        return options
    }

    private var menuBarOrderItems: [BookmarkMenuOrderItem] {
        BookmarkMenuSectionOrder.items(
            collections: model.collections,
            rawValue: menuBarSectionOrderRaw
        )
    }

    private func saveMenuBarSectionOrder(_ ids: [BookmarkMenuSectionID]) {
        menuBarSectionOrderRaw = BookmarkMenuSectionOrder.encoded(ids)
        model.notifyMenuPresentationChanged()
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
        performMenuBarOrderHapticIfNeeded()
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

    private func performMenuBarOrderHapticIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastMenuBarOrderHapticDate) >= 0.22 else { return }
        lastMenuBarOrderHapticDate = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private var hiddenBookmarkSections: [BookmarkListSection] {
        let bookmarks = filteredHiddenBookmarks
        return bookmarks.isEmpty ? [] : [BookmarkListSection(title: nil, bookmarks: bookmarks)]
    }

    private var archivedBookmarkSections: [BookmarkListSection] {
        let bookmarks = filtered(archivedBookmarks)
        return bookmarks.isEmpty ? [] : [BookmarkListSection(title: "归档书签", bookmarks: bookmarks)]
    }

    private func isEffectivelyArchived(_ bookmark: Bookmark) -> Bool {
        model.isEffectivelyArchived(bookmark)
    }

    private func filtered(_ bookmarks: [Bookmark]) -> [Bookmark] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return bookmarks
        }

        return bookmarks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.url.localizedCaseInsensitiveContains(query)
        }
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

    private var titleOptimizationIntensity: TitleOptimizationIntensity {
        get {
            TitleOptimizationIntensity(rawValue: titleOptimizationIntensityRaw) ?? .standard
        }
        nonmutating set {
            titleOptimizationIntensityRaw = newValue.rawValue
        }
    }

    private var titleOptimizationIntensityBinding: Binding<TitleOptimizationIntensity> {
        Binding(
            get: { titleOptimizationIntensity },
            set: { titleOptimizationIntensity = $0 }
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bookmark.url, forType: .string)
        showToast("已复制 URL")
    }

    private func setHidden(_ isHidden: Bool, for bookmark: Bookmark) {
        if let errorMessage = model.setHidden(isHidden, for: bookmark.id) {
            model.errorMessage = errorMessage
        } else {
            selection.remove(bookmark.id)
        }
    }

    private func setArchived(_ isArchived: Bool, for bookmark: Bookmark) {
        if let errorMessage = model.setArchived(isArchived, for: bookmark.id) {
            model.errorMessage = errorMessage
        } else {
            selection.remove(bookmark.id)
        }
    }

    private func setPinned(_ isPinned: Bool, for bookmark: Bookmark) {
        if let errorMessage = model.setPinned(isPinned, for: bookmark.id) {
            model.errorMessage = errorMessage
        } else if isPinned {
            showToast("已置顶")
        } else {
            showToast("已取消置顶")
        }
    }

    private func togglePinnedSelection() {
        guard canTogglePinnedSelection else { return }
        let isPinned = selectedPinnedTargetState
        if let errorMessage = model.setPinned(isPinned, for: selection) {
            model.errorMessage = errorMessage
        } else if isPinned {
            showToast(selection.count > 1 ? "已置顶 \(selection.count) 个书签" : "已置顶")
        } else {
            showToast(selection.count > 1 ? "已取消置顶 \(selection.count) 个书签" : "已取消置顶")
        }
    }

    private func openArchivedBookmark(_ bookmark: Bookmark) {
        if faviconLoader.image(for: bookmark.url) == nil {
            refreshFavicon(for: bookmark)
        }
        model.openArchivedBookmark(bookmark)
        selection.remove(bookmark.id)
    }

    private func openBookmark(_ bookmark: Bookmark) {
        if faviconLoader.image(for: bookmark.url) == nil {
            refreshFavicon(for: bookmark)
        }
        model.openBookmark(bookmark)
        selection.remove(bookmark.id)
    }

    private func syncArchiveSettings() {
        archiveAfterDays = BookmarksModel.clampedArchiveAfterDays(archiveAfterDays)
        model.reload()
    }

    private func refreshFavicon(for bookmark: Bookmark) {
        faviconLoader.refresh(urlString: bookmark.url)
        showToast("刷新 favicon 成功")
    }

    private func refreshAllFavicons() {
        faviconLoader.refreshAll(urlStrings: model.bookmarks.map(\.url))
        showToast("刷新全部 favicon 成功")
    }

    private func openHiddenBookmark(_ bookmark: Bookmark) {
        if faviconLoader.image(for: bookmark.url) == nil {
            refreshFavicon(for: bookmark)
        }
        guard openHiddenBookmarksIncognito else {
            guard let url = URL(string: bookmark.url) else { return }
            if NSWorkspace.shared.open(url) {
                model.recordUsage(for: bookmark)
            }
            return
        }

        switch PrivateBrowserOpener.openIncognito(urlString: bookmark.url) {
        case .opened:
            model.recordUsage(for: bookmark)
        case .unsupportedBrowser:
            showToast("当前默认浏览器不支持无痕打开", kind: .error)
        case .invalidURL:
            showToast("网址格式不正确", kind: .error)
        case .openFailed:
            showToast("无法打开无痕窗口", kind: .error)
        case .automationPermissionRequired:
            showToast("请允许 Obelisk 控制电脑后重试", kind: .error)
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

    private var selectedUnoptimizedTitleCount: Int {
        model.bookmarks.filter { selection.contains($0.id) && !$0.titleOptimized }.count
    }

    private func optimizeSelectedTitles() {
        Task {
            let message = await model.optimizeTitles(bookmarkIds: selection)
            showToast(message)
        }
    }

    private func revertTitleOptimizations(bookmarkIds: Set<Bookmark.ID>) {
        if let message = model.revertTitleOptimizations(bookmarkIds: bookmarkIds) {
            showToast(message, kind: message.hasPrefix("已恢复") ? .success : .error)
        }
    }

    private func restoreAllOriginalTitles() {
        let message = model.restoreAllOriginalTitles()
        showToast(message, kind: message.hasPrefix("已恢复") ? .success : .error)
    }

    private func fetchAllOriginalTitles() {
        guard developerFeaturesEnabled else {
            showToast("开发者选项已关闭", kind: .error)
            return
        }

        Task {
            isFetchingOriginalTitles = true
            let message = await model.fetchAllOriginalTitles()
            isFetchingOriginalTitles = false
            showToast(message)
        }
    }

    private func enableDeveloperFeatures() {
        developerFeaturesEnabled = true
        enableDeveloperFeaturesConfirmation = false
    }

    private func resetDeveloperOptionsToDefaults() {
        sidebarIconTileSize = BookmarksModel.defaultDebugSidebarIconTileSize
        sidebarIconSymbolSize = BookmarksModel.defaultDebugSidebarIconSymbolSize
        sidebarIconCornerRadius = BookmarksModel.defaultDebugSidebarIconCornerRadius
        resetDeveloperOptionsConfirmation = false
        showToast("已恢复开发者选项默认值")
    }

    private func createPlaintextDataBackup() {
        guard developerFeaturesEnabled else {
            showToast("开发者选项已关闭", kind: .error)
            return
        }
        guard !isCreatingPlaintextBackup else { return }

        isCreatingPlaintextBackup = true
        let rootDirectory = model.rootDirectory
        Task.detached(priority: .utility) {
            do {
                let result = try ObeliskPlaintextDataBackup.createBackup(in: rootDirectory)
                await MainActor.run {
                    isCreatingPlaintextBackup = false
                    showToast("已备份至 \(result.destinationURL.lastPathComponent)")
                }
            } catch {
                await MainActor.run {
                    isCreatingPlaintextBackup = false
                    showToast(error.localizedDescription, kind: .error)
                }
            }
        }
    }

    private func showToast(_ message: String, kind: Toast.Kind = .success) {
        withAnimation(.spring(duration: 0.24, bounce: 0.18)) {
            toast = Toast(message: message, kind: kind)
        }
    }

    private var llmConfigStore: LLMConfigStore {
        LLMConfigStore(rootDirectory: model.rootDirectory)
    }

    private func loadLLMConfig() {
        llmProfiles = llmConfigStore.loadProfiles()
    }

    private func persistLLMConfig(_ profiles: LLMProfilesSettings) {
        llmProfiles = profiles

        do {
            try llmConfigStore.save(profiles)
        } catch {
            // Auto-save failures are intentionally quiet; users can verify the
            // current fields with "测试模型连接".
        }
    }

    private func testLLMConfig() {
        guard !isTestingLLMConfig else { return }
        isTestingLLMConfig = true
        let config = llmProfiles.activeConfig
        Task {
            do {
                _ = try await TitleOptimizer(rootDirectory: model.rootDirectory).benchmark(config: config)
                showToast("连接成功")
            } catch {
                showToast("连接失败", kind: .error)
            }
            isTestingLLMConfig = false
        }
    }

    private func setLocalJSONEncryptionEnabled(_ isEnabled: Bool) {
        if !isEnabled {
            Task {
                guard await AuthenticationGate.authenticate(reason: "关闭本地数据加密") else {
                    await MainActor.run {
                        encryptLocalJSONData = true
                    }
                    return
                }
                await MainActor.run {
                    applyLocalJSONEncryptionEnabled(false)
                }
            }
            return
        }

        applyLocalJSONEncryptionEnabled(true)
    }

    private func applyLocalJSONEncryptionEnabled(_ isEnabled: Bool) {
        let previousValue = encryptLocalJSONData
        encryptLocalJSONData = isEnabled
        LocalJSONEncryption.isEnabled = isEnabled

        do {
            let backup = try migrateLocalPrivateStorage(isEnabled: isEnabled)
            onStorageRootChanged(model.rootDirectory)
            model.reload()
            loadLLMConfig()
            let backupSuffix = backup.map { "，已备份至 \($0.destinationURL.lastPathComponent)" } ?? ""
            showToast((isEnabled ? "数据加密已开启" : "数据加密已关闭") + backupSuffix)
        } catch {
            encryptLocalJSONData = previousValue
            LocalJSONEncryption.isEnabled = previousValue
            llmConfigMessage = error.localizedDescription
        }
    }

    private func migrateLocalPrivateStorage(isEnabled: Bool) throws -> ObeliskPlaintextDataBackup.Result? {
        let root = model.rootDirectory
        let backup = try ObeliskStorageTransition.backUpThenNormalize(in: root, encrypted: isEnabled)

        faviconLoader.reloadStorage()
        return backup
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

    private var refreshAllFaviconAlertBinding: Binding<Bool> {
        Binding(
            get: { refreshAllFaviconConfirmation },
            set: { if !$0 { refreshAllFaviconConfirmation = false } }
        )
    }

    private var restoreAllOriginalTitlesAlertBinding: Binding<Bool> {
        Binding(
            get: { restoreAllOriginalTitlesConfirmation },
            set: { if !$0 { restoreAllOriginalTitlesConfirmation = false } }
        )
    }

    private var refetchAllOriginalTitlesAlertBinding: Binding<Bool> {
        Binding(
            get: { refetchAllOriginalTitlesConfirmation },
            set: { if !$0 { refetchAllOriginalTitlesConfirmation = false } }
        )
    }

    private var developerFeaturesEnabledBinding: Binding<Bool> {
        Binding(
            get: { developerFeaturesEnabled },
            set: { newValue in
                if newValue {
                    enableDeveloperFeaturesConfirmation = true
                } else {
                    developerFeaturesEnabled = false
                }
            }
        )
    }

    private var enableDeveloperFeaturesAlertBinding: Binding<Bool> {
        Binding(
            get: { enableDeveloperFeaturesConfirmation },
            set: { if !$0 { enableDeveloperFeaturesConfirmation = false } }
        )
    }

    private var resetDeveloperOptionsAlertBinding: Binding<Bool> {
        Binding(
            get: { resetDeveloperOptionsConfirmation },
            set: { if !$0 { resetDeveloperOptionsConfirmation = false } }
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
        .environment(\.sidebarIconTileSize, sidebarIconTileSize)
        .environment(\.sidebarIconSymbolSize, sidebarIconSymbolSize)
        .environment(\.sidebarIconCornerRadius, sidebarIconCornerRadius)
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索书签")
        .toolbar {
            settingsToolbar
        }
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
                    prefilledIsHidden: prefilledIsHidden
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
        }
        .onChange(of: addRequest.seq) { _, _ in
            consumePendingAddRequestIfNeeded()
        }
        .onChange(of: settingsPage) { _, _ in
            selectedCollectionId = nil
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
            Text("共计删除 \(confirmation.count) 个书签。")
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
        .modifier(ExtraAlerts(
            refreshAllFaviconAlertBinding: refreshAllFaviconAlertBinding,
            refreshAllFaviconConfirmation: $refreshAllFaviconConfirmation,
            refreshAllFavicons: refreshAllFavicons,
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
            deleteCollection: deleteCollection,
            restoreAllOriginalTitlesAlertBinding: restoreAllOriginalTitlesAlertBinding,
            restoreAllOriginalTitlesConfirmation: $restoreAllOriginalTitlesConfirmation,
            restoreAllOriginalTitles: restoreAllOriginalTitles,
            refetchAllOriginalTitlesAlertBinding: refetchAllOriginalTitlesAlertBinding,
            refetchAllOriginalTitlesConfirmation: $refetchAllOriginalTitlesConfirmation,
            fetchAllOriginalTitles: fetchAllOriginalTitles,
            enableDeveloperFeaturesAlertBinding: enableDeveloperFeaturesAlertBinding,
            enableDeveloperFeaturesConfirmation: $enableDeveloperFeaturesConfirmation,
            enableDeveloperFeatures: enableDeveloperFeatures,
            resetDeveloperOptionsAlertBinding: resetDeveloperOptionsAlertBinding,
            resetDeveloperOptionsConfirmation: $resetDeveloperOptionsConfirmation,
            resetDeveloperOptionsToDefaults: resetDeveloperOptionsToDefaults
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
        List(selection: settingsPageBinding) {
            // 顶部：书签 / 隐藏书签 直接铺开，不带分组标题。
            ForEach(visibleSettingsPages.filter { $0.group == .content }) { page in
                NavigationLink(value: page) {
                    SidebarPageLabel(page: page)
                }
            }

            // 其余按 group 分 Section，跳过 .content 避免重复。
            ForEach(SettingsPage.Group.allCases.filter { $0 != .content }) { group in
                let pages = visibleSettingsPages.filter { $0.group == group }
                if !pages.isEmpty {
                    Section(group.rawValue) {
                        ForEach(pages) { page in
                            NavigationLink(value: page) {
                                SidebarPageLabel(page: page)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("设置")
        .navigationSplitViewColumnWidth(min: 150, ideal: 180)
    }

    private var visibleSettingsPages: [SettingsPage] {
        SettingsPage.allCases.filter { page in
            page != .hiddenBookmarks || showHiddenBookmarksPage
        }
    }

    private var bookmarkSortMenu: some View {
        sortMenu(selection: bookmarkListSortModeBinding)
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

    private var titleIntensityPicker: some View {
        CompactBorderedMenuPicker(
            options: Array(TitleOptimizationIntensity.allCases),
            selection: titleOptimizationIntensityBinding,
            title: { $0.title }
        )
    }

    private var llmModelSourcePicker: some View {
        CompactBorderedMenuPicker(
            options: Array(LLMModelSource.allCases),
            selection: llmModelSourceBinding,
            title: { $0.title }
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
                aiOptimizationPage
            case .privacy:
                privacyPage
            case .developer:
                developerOptionsPage
            }
        }
        .navigationTitle(settingsPage.title)
    }

    private var bookmarkManagementPage: some View {
        Group {
            if model.bookmarks.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("还没有书签")
                    } icon: {
                        Image(nsImage: AppIcon.image(size: NSSize(width: 28, height: 28)))
                    }
                } description: {
                    Text("点击工具栏的 + 添加你的第一个书签。")
                }
            } else if bookmarkSections.isEmpty {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if !model.visibleCollectionSections(sortMode: collectionListSortMode).isEmpty {
                    ContentUnavailableView {
                        Label("没有未分组的书签", systemImage: "bookmark")
                    } description: {
                        Text("已放入分组的书签在「分组」页查看。")
                    }
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                NativeBookmarkList(
                    sections: bookmarkSections,
                    selection: $selection,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onOpen: { bookmark in openBookmark(bookmark) },
                    onCopyURL: { bookmark in copyURL(bookmark) },
                    onRefreshFavicon: { bookmark in refreshFavicon(for: bookmark) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "移到隐藏书签",
                    onSetHidden: { bookmark in setHidden(true, for: bookmark) },
                    archiveStateActionTitle: autoArchiveEnabled ? "归档" : nil,
                    onSetArchived: autoArchiveEnabled ? { bookmark in setArchived(true, for: bookmark) } : nil,
                    pinStateActionTitle: { $0.isPinned ? "取消置顶" : "置顶" },
                    onSetPinned: { bookmark in setPinned(!bookmark.isPinned, for: bookmark) },
                    onSortModeChange: { sortMode in bookmarkListSortMode = sortMode },
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: { bookmarkIds, collectionId in
                        assignCollection(bookmarkIds: bookmarkIds, collectionId: collectionId)
                    },
                    onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                )
            }
        }
        .navigationTitle("书签")
    }

    private var collectionsManagementPage: some View {
        Group {
            if model.collections.isEmpty {
                ContentUnavailableView {
                    Label("还没有分组", systemImage: "folder")
                } description: {
                    Text("点击工具栏 + 创建分组。")
                }
            } else if collectionBookmarkSections.allSatisfy({ $0.bookmarks.isEmpty })
                && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if collectionBookmarkSections.allSatisfy({ $0.bookmarks.isEmpty }) {
                NativeBookmarkList(
                    sections: collectionBookmarkSections,
                    selection: $selection,
                    selectedCollectionId: $selectedCollectionId,
                    faviconLoader: faviconLoader,
                    faviconVersion: faviconLoader.version,
                    showsURLHostOnly: showsURLHostOnly,
                    onSortModeChange: { sortMode in collectionListSortMode = sortMode },
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
                    onOpen: { bookmark in openBookmark(bookmark) },
                    onCopyURL: { bookmark in copyURL(bookmark) },
                    onRefreshFavicon: { bookmark in refreshFavicon(for: bookmark) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "移到隐藏书签",
                    onSetHidden: { bookmark in setHidden(true, for: bookmark) },
                    archiveStateActionTitle: autoArchiveEnabled ? "归档" : nil,
                    onSetArchived: autoArchiveEnabled ? { bookmark in setArchived(true, for: bookmark) } : nil,
                    pinStateActionTitle: { $0.isPinned ? "取消置顶" : "置顶" },
                    onSetPinned: { bookmark in setPinned(!bookmark.isPinned, for: bookmark) },
                    onSortModeChange: { sortMode in collectionListSortMode = sortMode },
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: { bookmarkIds, collectionId in
                        assignCollection(bookmarkIds: bookmarkIds, collectionId: collectionId)
                    },
                    onRenameCollection: { id in beginRenameCollection(id: id) },
                    onDeleteCollection: { id in beginDeleteCollection(id: id) },
                    onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                )
            }
        }
        .navigationTitle("分组")
    }

    private var hiddenBookmarkManagementPage: some View {
        Group {
            if hiddenBookmarks.isEmpty {
                ContentUnavailableView {
                    Label("还没有隐藏书签", systemImage: "eye.slash")
                } description: {
                    Text("按 ⌥H 可以把当前浏览器标签添加为隐藏书签。")
                }
            } else if filteredHiddenBookmarks.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                VStack(alignment: .leading, spacing: 0) {
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
                        onOpen: { bookmark in openHiddenBookmark(bookmark) },
                        onCopyURL: { bookmark in copyURL(bookmark) },
                        onRefreshFavicon: { bookmark in refreshFavicon(for: bookmark) },
                        onEdit: { bookmark in presentation = .edit(bookmark) },
                        onDelete: { ids in requestDelete(ids: ids) },
                        hiddenStateActionTitle: "恢复到书签",
                        onSetHidden: { bookmark in setHidden(false, for: bookmark) },
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
                            Text("开启后 Obelisk 会自动归档您一段时间没有使用的书签。")
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

            if autoArchiveEnabled {
                if archivedBookmarks.isEmpty {
                    ContentUnavailableView {
                        Label("没有归档书签", systemImage: "archivebox")
                    } description: {
                        Text("闲置书签会在达到设定天数后自动归档。")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if archivedBookmarkSections.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    NativeBookmarkList(
                        sections: archivedBookmarkSections,
                        selection: $selection,
                        faviconLoader: faviconLoader,
                        faviconVersion: faviconLoader.version,
                        showsURLHostOnly: showsURLHostOnly,
                        onOpen: { bookmark in openArchivedBookmark(bookmark) },
                        onCopyURL: { bookmark in copyURL(bookmark) },
                        onRefreshFavicon: { bookmark in refreshFavicon(for: bookmark) },
                        onEdit: { bookmark in presentation = .edit(bookmark) },
                        onDelete: { ids in requestDelete(ids: ids) },
                        archiveStateActionTitle: "恢复到书签",
                        onSetArchived: { bookmark in setArchived(false, for: bookmark) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("归档")
    }

    private var appearancePage: some View {
        Form {
            Section("窗口") {
                Toggle(isOn: $windowTransparencyEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("启用窗口透明效果")
                        Text("为设置窗口启用 Liquid Glass 半透明材质。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if windowTransparencyEnabled {
                    Toggle(isOn: customTransparencyBinding) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自定义透明度")
                            Text("开启后可手动调整窗口透明度。")
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
                        Text("开启后书签列表会显示完整 URL。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("菜单栏") {
                menuLimitStepper("最近添加数量", desc: "菜单栏智能置顶「最近添加」最多显示的书签数量。", value: $menuRecentGroupLimit)
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
        .animation(.easeInOut(duration: 0.12), value: menuBarOrderItems.map(\.id))
        .onDisappear(perform: resetMenuBarOrderDrag)
        .navigationTitle("菜单栏")
    }

    private var menuBarOrderCard: some View {
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
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.regularMaterial)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .offset(y: CGFloat(startIndex) * menuBarOrderRowHeight + menuBarDragOffsetY)
                    .zIndex(2)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: CGFloat(items.count) * menuBarOrderRowHeight)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(menuBarOrderCardBackgroundColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.035), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func menuBarOrderRow(
        for item: BookmarkMenuOrderItem,
        isPlaceholder: Bool,
        isDropTarget: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Text(item.title)
                .lineLimit(1)

            Spacer(minLength: 16)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
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
                    performMenuBarOrderHapticIfNeeded()
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
                Toggle(isOn: $silentAddEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("静默添加书签")
                        Text("按 ⌥B / ⌥H 后直接将当前浏览器标签加入书签，不弹出设置窗口，改为菜单栏提醒。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if silentAddEnabled, aiFeaturesEnabled {
                    Toggle(isOn: $autoOptimizeNewBookmarks) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动优化新书签标题")
                            Text("静默添加后自动使用已配置的模型优化书签标题。")
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
        .navigationTitle("快捷键")
    }

    private func menuLimitStepper(_ title: String, desc: String? = nil, value: Binding<Int>) -> some View {
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
                Section("Intelligence 标题优化") {
                    LabeledContent {
                        titleIntensityPicker
                            // SwiftUI gives this picker a larger trailing inset
                            // than the model source row; keep the chevrons aligned.
                            .padding(.trailing, -12)
                    } label: {
                        Text("优化程度")
                    }

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
                            prompt: Text(llmProfiles.activeSource == .remote ? "sk-..." : "lm-studio")
                        ) {
                            Label("API Key", systemImage: "key")
                        }
                        Text(
                            llmProfiles.activeSource == .remote
                                ? "用于访问云端 OpenAI 兼容服务的 API Key。"
                                : "本地服务通常不校验 Key，填任意非空字符串即可。"
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
                                ? "远程服务的模型名称，如 gpt-4.1-mini。"
                                : "须与 LM Studio Local Server 里已加载模型的 id 一致。"
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
                                ? "远程 API 的 chat completions 地址。"
                                : "须先在本机启动 LM Studio Local Server（默认端口 1234）。"
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

    private var privacyPage: some View {
        Form {
            Section("安全") {
                Toggle(
                    isOn: Binding(
                        get: { encryptLocalJSONData },
                        set: { setLocalJSONEncryptionEnabled($0) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("开启加密功能")
                        Text("开启后 Obelisk 会使用 AES-GCM 加密您的书签、使用记录、模型配置和 favicon 缓存。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .help("开启后 Obelisk 会使用 AES-GCM 加密您的书签、使用记录、模型配置和 favicon 缓存。")
            }

            Section("隐藏书签") {
                Toggle(isOn: $openHiddenBookmarksIncognito) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("使用无痕窗口打开隐藏书签")
                        Text("Dia 会复用 Obelisk 创建的无痕窗口；其他 Chromium 浏览器使用启动参数。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("隐私")
    }

    private var developerOptionsPage: some View {
        Form {
            Section("开发者选项") {
                Toggle("开启开发者选项", isOn: developerFeaturesEnabledBinding)
            }

            if developerFeaturesEnabled {
                Section("数据备份") {
                    LabeledContent {
                        Button {
                            createPlaintextDataBackup()
                        } label: {
                            Text(isCreatingPlaintextBackup ? "备份中…" : "备份")
                        }
                        .disabled(isCreatingPlaintextBackup)
                    } label: {
                        Text("备份明文数据")
                    }
                }

                Section("Favicon") {
                    LabeledContent {
                        Button(role: .destructive) {
                            refreshAllFaviconConfirmation = true
                        } label: {
                            Text("刷新")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("刷新全部 favicon")
                            Text("重新下载所有书签的网站图标，此操作不可撤销。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Toast 调试") {
                    HStack(spacing: 10) {
                        Button("成功 Toast") {
                            showToast("操作成功")
                        }

                        Button("失败 Toast") {
                            showToast("操作失败", kind: .error)
                        }
                    }
                }

                Section("侧栏图标调试") {
                    centeredValueSlider("背景尺寸", desc: "侧栏图标背景色块的尺寸。", value: $sidebarIconTileSize, range: 16...28)
                    centeredValueSlider("符号尺寸", desc: "侧栏图标中 SF Symbol 的字体大小。", value: $sidebarIconSymbolSize, range: 6...16)
                    centeredValueSlider("圆角", desc: "侧栏图标背景色块的圆角半径。", value: $sidebarIconCornerRadius, range: 2...10)
                }

                Section("标题") {
                    LabeledContent {
                        Button(role: .destructive) {
                            restoreAllOriginalTitlesConfirmation = true
                        } label: {
                            Text("恢复")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(isFetchingOriginalTitles || model.bookmarks.isEmpty || model.isOptimizingTitles)
                    } label: {
                        Text("恢复全部原标题")
                    }

                    LabeledContent {
                        Button(role: .destructive) {
                            refetchAllOriginalTitlesConfirmation = true
                        } label: {
                            Text(isFetchingOriginalTitles ? "获取中…" : "覆盖")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(isFetchingOriginalTitles || model.bookmarks.isEmpty || model.isOptimizingTitles)
                    } label: {
                        Text("重新获取并覆盖全部标题")
                    }
                }

                Section("高级") {
                    Button("恢复默认设置") {
                        resetDeveloperOptionsConfirmation = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("开发者选项")
    }

    private func centeredValueSlider(
        _ title: LocalizedStringKey,
        desc: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                Text(title)
                    .frame(width: 72, alignment: .leading)

                Slider(value: value, in: range, step: 1)

                Text("\(Int(value.wrappedValue))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }

            if let desc {
                Text(desc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        if settingsPage == .bookmarks {
            ToolbarSpacer(.flexible)

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
                    requestDelete(ids: selection)
                } label: {
                    Label("删除", systemImage: "minus")
                }
                .disabled(!canDeleteSelection)
                .help("删除选中的书签")

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
                    Label(selectedPinnedTargetState ? "置顶" : "取消置顶", systemImage: "pin")
                }
                .disabled(!canTogglePinnedSelection)
                .help(selectedPinnedTargetState ? "置顶选中的书签" : "取消置顶选中的书签")
            }

            if aiFeaturesEnabled {
                ToolbarSpacer(.fixed)

                ToolbarItem {
                    Button {
                        optimizeSelectedTitles()
                    } label: {
                        Label(
                            model.isOptimizingTitles ? "优化中" : "优化标题",
                            systemImage: "apple.intelligence"
                        )
                    }
                    .disabled(selection.isEmpty || model.isOptimizingTitles || selectedUnoptimizedTitleCount == 0)
                }
            }
        } else if settingsPage == .collections {
            ToolbarSpacer(.flexible)

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
                    requestDeleteCollectionPageSelection()
                } label: {
                    Label("删除", systemImage: "minus")
                }
                .disabled(!canDeleteCollectionPageSelection)
                .help("删除选中的分组")

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
                    Label(selectedPinnedTargetState ? "置顶" : "取消置顶", systemImage: "pin")
                }
                .disabled(!canTogglePinnedSelection)
                .help(selectedPinnedTargetState ? "置顶选中的书签" : "取消置顶选中的书签")
            }

            if aiFeaturesEnabled {
                ToolbarSpacer(.fixed)

                ToolbarItem {
                    Button {
                        optimizeSelectedTitles()
                    } label: {
                        Label(
                            model.isOptimizingTitles ? "优化中" : "优化标题",
                            systemImage: "apple.intelligence"
                        )
                    }
                    .disabled(selection.isEmpty || model.isOptimizingTitles || selectedUnoptimizedTitleCount == 0)
                }
            }
        } else if settingsPage == .hiddenBookmarks {
            ToolbarSpacer(.flexible)

            ToolbarItemGroup {
                Button {
                    presentation = .add(seq: 0, prefilledURL: nil, prefilledTitle: nil, prefilledIsHidden: true)
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .disabled(selection.count > 1)
                .help("添加隐藏书签")

                Button {
                    requestDelete(ids: selection)
                } label: {
                    Label("删除", systemImage: "minus")
                }
                .disabled(!canDeleteSelection)
                .help("删除选中的隐藏书签")

                Button {
                    if let bookmark = selectedBookmark {
                        presentation = .edit(bookmark)
                    }
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .disabled(!canUseSingleSelectionActions)
            }

            if aiFeaturesEnabled {
                ToolbarSpacer(.fixed)

                ToolbarItem {
                    Button {
                        optimizeSelectedTitles()
                    } label: {
                        Label(
                            model.isOptimizingTitles ? "优化中" : "优化标题",
                            systemImage: "apple.intelligence"
                        )
                    }
                    .disabled(selection.isEmpty || model.isOptimizingTitles || selectedUnoptimizedTitleCount == 0)
                }
            }
        }
    }
}

private struct SidebarPageLabel: View {
    let page: BookmarkManagerView.SettingsPage

    var body: some View {
        HStack(spacing: 12) {
            SidebarCategoryIcon(page: page)

            Text(page.title)
        }
    }
}

private struct SidebarCategoryIcon: View {
    let page: BookmarkManagerView.SettingsPage
    @Environment(\.sidebarIconTileSize) private var tileSize
    @Environment(\.sidebarIconSymbolSize) private var symbolSize
    @Environment(\.sidebarIconCornerRadius) private var cornerRadius

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(page.iconGradient)
                .overlay {
                    if page == .ai {
                        IntelligenceTileOverlay(cornerRadius: cornerRadius)
                    }
                }

            Image(systemName: page.symbolName)
                .font(.system(size: symbolSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
        .frame(width: tileSize, height: tileSize)
    }
}

private struct IntelligenceTileOverlay: View {
    let cornerRadius: Double

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                RadialGradient(
                    colors: [
                        Color(red: 0.70, green: 0.90, blue: 0.72).opacity(0.96),
                        Color(red: 0.70, green: 0.90, blue: 0.72).opacity(0.0)
                    ],
                    center: UnitPoint(x: 0.28, y: 0.55),
                    startRadius: 0,
                    endRadius: 22
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 1.0, green: 0.18, blue: 0.36).opacity(0.78),
                                Color(red: 1.0, green: 0.18, blue: 0.36).opacity(0.0)
                            ],
                            center: UnitPoint(x: 0.82, y: 0.18),
                            startRadius: 0,
                            endRadius: 20
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.24, green: 0.66, blue: 1.0).opacity(0.78),
                                Color(red: 0.24, green: 0.66, blue: 1.0).opacity(0.0)
                            ],
                            center: UnitPoint(x: 0.14, y: 0.92),
                            startRadius: 0,
                            endRadius: 18
                        )
                    )
            }
    }
}

private struct SidebarIconTileSizeKey: EnvironmentKey {
    static let defaultValue: Double = 32
}

private struct SidebarIconSymbolSizeKey: EnvironmentKey {
    static let defaultValue: Double = 15
}

private struct SidebarIconCornerRadiusKey: EnvironmentKey {
    static let defaultValue: Double = 8
}

private extension EnvironmentValues {
    var sidebarIconTileSize: Double {
        get { self[SidebarIconTileSizeKey.self] }
        set { self[SidebarIconTileSizeKey.self] = newValue }
    }

    var sidebarIconSymbolSize: Double {
        get { self[SidebarIconSymbolSizeKey.self] }
        set { self[SidebarIconSymbolSizeKey.self] = newValue }
    }

    var sidebarIconCornerRadius: Double {
        get { self[SidebarIconCornerRadiusKey.self] }
        set { self[SidebarIconCornerRadiusKey.self] = newValue }
    }
}

private extension View {
    func settingsContentMargins() -> some View {
        self
            .contentMargins(.horizontal, 18, for: .scrollContent)
            .contentMargins(.top, 0, for: .scrollContent)
    }
}

private struct BookmarkRow: View {
    let bookmark: Bookmark
    let faviconLoader: FaviconLoader

    var body: some View {
        // Subscribe to loader.version so newly cached favicons trigger a redraw.
        _ = faviconLoader.version
        let icon = faviconLoader.image(for: bookmark.url)

        return HStack(spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                } else {
                    Image(nsImage: AppIcon.faviconPlaceholder(size: NSSize(width: 16, height: 16)))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.title)
                    .font(.body)
                Text(bookmark.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct BookmarkEditor: View {
    enum Mode {
        case add
        case edit(Bookmark)

        var title: String {
            switch self {
            case .add: return "添加书签"
            case .edit: return "编辑书签"
            }
        }
    }

    let mode: Mode
    @Bindable var model: BookmarksModel
    /// Optional prefilled values. Set by the global hotkey path (Wave 5)
    /// when we have URL+title from the frontmost browser. When non-nil,
    /// these win over clipboard-URL detection.
    var prefilledURL: String? = nil
    var prefilledTitle: String? = nil
    var prefilledIsHidden: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var url: String = ""
    @State private var isHidden = false
    @State private var isFetchingTitle = false
    /// Tracks whether the user has typed in the title field. We never
    /// overwrite a manual title with an auto-fetched one.
    @State private var titleEditedByUser = false
    @State private var titleFetchTask: Task<Void, Never>?
    @State private var lastFetchedURL: String?
    /// Per-sheet error so the alert presents on top of the sheet instead
    /// of being queued behind it on the parent view.
    @State private var commitErrorMessage: String?

    private static let metadataFetcher = PageMetadataFetcher()

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("标题", text: $title, prompt: Text("例如:GitHub"))
                        .onChange(of: title) { _, _ in
                            // Distinguish user typing from our own programmatic
                            // assignment after a fetch.
                            if !isProgrammaticTitleUpdate {
                                titleEditedByUser = true
                            }
                        }
                    if isFetchingTitle {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                TextField("网址", text: $url, prompt: Text("https://example.com"))
                    .textContentType(.URL)
                    .onChange(of: url) { _, newValue in
                        scheduleTitleFetch(for: newValue)
                    }
                Toggle("隐藏书签", isOn: $isHidden)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(mode.title)
        .frame(minWidth: 420)
        .padding(.top, 4)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saveLabel) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .alert(
            "无法保存书签",
            isPresented: Binding(
                get: { commitErrorMessage != nil },
                set: { if !$0 { commitErrorMessage = nil } }
            ),
            presenting: commitErrorMessage
        ) { _ in
            Button("好") { commitErrorMessage = nil }
        } message: { msg in
            Text(msg)
        }
        .onAppear {
            switch mode {
            case .edit(let bookmark):
                isProgrammaticTitleUpdate = true
                title = bookmark.title
                url = bookmark.url
                isHidden = bookmark.isHidden
                isProgrammaticTitleUpdate = false
                // Don't auto-fetch when editing: preserve whatever the user already saved.
                titleEditedByUser = true
            case .add:
                isHidden = prefilledIsHidden
                // Prefill from the global hotkey path takes precedence:
                // a real browser-tab snapshot beats whatever happens to
                // be on the clipboard. If a title is supplied, mark it as
                // user-edited so the auto-fetch doesn't overwrite it.
                if let prefilledURL, !prefilledURL.isEmpty {
                    url = prefilledURL
                    if let prefilledTitle, !prefilledTitle.isEmpty {
                        isProgrammaticTitleUpdate = true
                        title = prefilledTitle
                        isProgrammaticTitleUpdate = false
                        titleEditedByUser = true
                    }
                } else if let clipboard = clipboardURL() {
                    url = clipboard
                    // The url onChange handler will schedule the title fetch.
                }
            }
        }
        .onDisappear {
            titleFetchTask?.cancel()
        }
    }

    @State private var isProgrammaticTitleUpdate = false

    private var saveLabel: String {
        switch mode {
        case .add: return "添加"
        case .edit: return "保存"
        }
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commit() {
        let errorMessage: String?
        switch mode {
        case .add:
            errorMessage = model.add(title: title, url: url, isHidden: isHidden)
        case .edit(let bookmark):
            var updated = bookmark
            updated.title = title
            updated.url = url
            updated.isHidden = isHidden
            errorMessage = model.update(updated)
        }
        if let errorMessage {
            commitErrorMessage = errorMessage
        } else {
            dismiss()
        }
    }

    // MARK: - Auto-fill helpers

    private func clipboardURL() -> String? {
        ClipboardURL.normalizedHTTPURL()
    }

    private func scheduleTitleFetch(for raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cancel any in-flight fetch — input is changing.
        titleFetchTask?.cancel()
        isFetchingTitle = false

        guard
            !titleEditedByUser,
            !trimmed.isEmpty,
            trimmed != lastFetchedURL,
            let parsed = URL(string: trimmed),
            let scheme = parsed.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            parsed.host?.isEmpty == false
        else { return }

        let urlSnapshot = trimmed
        isFetchingTitle = true

        titleFetchTask = Task { @MainActor in
            // Debounce: typing fast enough cancels the sleep.
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }

            guard let parsed = URL(string: urlSnapshot) else {
                isFetchingTitle = false
                return
            }
            let fetched = await Self.metadataFetcher.title(for: parsed)
            if Task.isCancelled { return }

            // Re-check preconditions: user may have started typing the title,
            // or changed the URL while we were fetching.
            if !titleEditedByUser, url.trimmingCharacters(in: .whitespacesAndNewlines) == urlSnapshot,
               let fetched, !fetched.isEmpty {
                isProgrammaticTitleUpdate = true
                title = fetched
                isProgrammaticTitleUpdate = false
            }
            lastFetchedURL = urlSnapshot
            isFetchingTitle = false
        }
    }
}

// MARK: - Hidden Bookmarks Locking

private struct HiddenBookmarksLockingModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Binding var settingsPage: BookmarkManagerView.SettingsPage
    @Binding var hiddenBookmarksUnlocked: Bool
    @Binding var showHiddenBookmarksPage: Bool
    @Binding var selection: Set<Bookmark.ID>

    func body(content: Content) -> some View {
        content
            .onChange(of: settingsPage) { oldPage, newPage in
                if oldPage == .hiddenBookmarks, newPage != .hiddenBookmarks {
                    hiddenBookmarksUnlocked = false
                }
                selection.removeAll()
            }
            .onChange(of: showHiddenBookmarksPage) { _, isShowing in
                if !isShowing, settingsPage == .hiddenBookmarks {
                    lockHiddenBookmarks()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active, settingsPage == .hiddenBookmarks {
                    lockHiddenBookmarks()
                }
            }
    }

    private func lockHiddenBookmarks() {
        settingsPage = .bookmarks
        hiddenBookmarksUnlocked = false
        selection.removeAll()
    }
}

// MARK: - Extra Alerts (split out to keep the main body type-checkable)

private struct ExtraAlerts: ViewModifier {
    let refreshAllFaviconAlertBinding: Binding<Bool>
    @Binding var refreshAllFaviconConfirmation: Bool
    let refreshAllFavicons: () -> Void
    let customTransparencyAlertBinding: Binding<Bool>
    @Binding var showCustomTransparencyAlert: Bool
    @Binding var customTransparencyEnabled: Bool
    @Binding var showNewCollectionDialog: Bool
    @Binding var newCollectionName: String
    let createCollection: () -> Void
    let renameCollectionAlertBinding: Binding<Bool>
    @Binding var renameCollectionName: String
    @Binding var collectionToRename: BookmarkCollection?
    let renameCollection: () -> Void
    let deleteCollectionAlertBinding: Binding<Bool>
    @Binding var collectionToDelete: BookmarkCollection?
    let deleteCollection: () -> Void
    let restoreAllOriginalTitlesAlertBinding: Binding<Bool>
    @Binding var restoreAllOriginalTitlesConfirmation: Bool
    let restoreAllOriginalTitles: () -> Void
    let refetchAllOriginalTitlesAlertBinding: Binding<Bool>
    @Binding var refetchAllOriginalTitlesConfirmation: Bool
    let fetchAllOriginalTitles: () -> Void
    let enableDeveloperFeaturesAlertBinding: Binding<Bool>
    @Binding var enableDeveloperFeaturesConfirmation: Bool
    let enableDeveloperFeatures: () -> Void
    let resetDeveloperOptionsAlertBinding: Binding<Bool>
    @Binding var resetDeveloperOptionsConfirmation: Bool
    let resetDeveloperOptionsToDefaults: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("新建分组", isPresented: $showNewCollectionDialog) {
                TextField("分组名称", text: $newCollectionName)
                Button("取消", role: .cancel) {}
                Button("创建", action: createCollection)
            }
            .alert("重命名分组", isPresented: renameCollectionAlertBinding) {
                TextField("分组名称", text: $renameCollectionName)
                Button("取消", role: .cancel) { collectionToRename = nil }
                Button("保存", action: renameCollection)
            }
            .alert(
                "删除分组?",
                isPresented: deleteCollectionAlertBinding,
                presenting: collectionToDelete
            ) { _ in
                Button("取消", role: .cancel) { collectionToDelete = nil }
                Button("删除", role: .destructive, action: deleteCollection)
            } message: { collection in
                Text("删除「\(collection.name)」后，其中的书签将移到未分组。")
            }
            .alert(
                "恢复全部原标题?",
                isPresented: restoreAllOriginalTitlesAlertBinding
            ) {
                Button("取消", role: .cancel) {
                    restoreAllOriginalTitlesConfirmation = false
                }
                Button("恢复", role: .destructive) {
                    restoreAllOriginalTitlesConfirmation = false
                    restoreAllOriginalTitles()
                }
            } message: {
                Text("将使用本地保存的原标题覆盖当前标题，此操作不可撤销。")
            }
            .alert(
                "重新获取并覆盖全部标题?",
                isPresented: refetchAllOriginalTitlesAlertBinding
            ) {
                Button("取消", role: .cancel) {
                    refetchAllOriginalTitlesConfirmation = false
                }
                Button("覆盖", role: .destructive) {
                    refetchAllOriginalTitlesConfirmation = false
                    fetchAllOriginalTitles()
                }
            } message: {
                Text("将从各书签网址抓取网页标题并应用到全部书签，已 Intelligence 优化的标题也会被覆盖。")
            }
            .alert(
                "刷新全部 favicon?",
                isPresented: refreshAllFaviconAlertBinding
            ) {
                Button("取消", role: .cancel) {
                    refreshAllFaviconConfirmation = false
                }
                Button("刷新", role: .destructive) {
                    refreshAllFavicons()
                    refreshAllFaviconConfirmation = false
                }
            } message: {
                Text("将清除所有已缓存的网站图标并重新下载，此操作不可撤销。")
            }
            .alert(
                "开启自定义透明度?",
                isPresented: customTransparencyAlertBinding
            ) {
                Button("取消", role: .cancel) {
                    showCustomTransparencyAlert = false
                }
                Button("确定") {
                    customTransparencyEnabled = true
                    showCustomTransparencyAlert = false
                }
            } message: {
                Text("你确定吗？开启自定义透明度可能会大幅降低可读性。")
            }
            .alert(
                "开启开发者选项?",
                isPresented: enableDeveloperFeaturesAlertBinding
            ) {
                Button("取消", role: .cancel) {
                    enableDeveloperFeaturesConfirmation = false
                }
                Button("开启", role: .destructive) {
                    enableDeveloperFeatures()
                }
            } message: {
                Text("修改「开发者选项」中的任意一项配置都可能导致 Obelisk 出现非预期的变化、甚至崩溃和数据丢失，如果你不清楚设置和选项的含义，请不要修改任何内容，并保持「开发者选项」关闭。")
            }
            .alert(
                "恢复默认设置?",
                isPresented: resetDeveloperOptionsAlertBinding
            ) {
                Button("取消", role: .cancel) {
                    resetDeveloperOptionsConfirmation = false
                }
                Button("恢复", role: .destructive) {
                    resetDeveloperOptionsToDefaults()
                }
            } message: {
                Text("将把侧栏图标调试参数恢复为默认值，不会修改书签数据。")
            }
    }
}
