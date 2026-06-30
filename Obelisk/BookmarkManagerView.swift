import AppKit
import Carbon.HIToolbox
import SwiftUI

enum BookmarkListSortMode: String, CaseIterable, Identifiable {
    case name
    case recentlyAdded
    case frequency

    static let bookmarksStorageKey = "bookmarkListSortMode"
    static let pinnedStorageKey = "pinnedBookmarkListSortMode"
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

    static var stored: BookmarkListSortMode { storedForUngrouped }
    static var storedForBookmarks: BookmarkListSortMode { storedForUngrouped }
    static var storedForUngrouped: BookmarkListSortMode { stored(for: bookmarksStorageKey) }
    static var storedForPinned: BookmarkListSortMode {
        migratePinnedSortModeIfNeeded()
        return stored(for: pinnedStorageKey)
    }
    static var storedForCollections: BookmarkListSortMode { stored(for: collectionsStorageKey) }
    static var storedForHiddenBookmarks: BookmarkListSortMode { stored(for: hiddenStorageKey) }

    static func migratePinnedSortModeIfNeeded(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: pinnedStorageKey) == nil else { return }
        if let raw = defaults.string(forKey: bookmarksStorageKey),
           BookmarkListSortMode(rawValue: raw) != nil {
            defaults.set(raw, forKey: pinnedStorageKey)
        }
    }

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

private enum BookmarkDisplayMode: String, CaseIterable, Identifiable {
    case list
    case dateGrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "列表"
        case .dateGrid: return "表格"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .dateGrid: return "square.grid.2x2"
        }
    }
}

enum BookmarkSearchMatcher {
    static func matches(bookmark: Bookmark, query: String) -> Bool {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return true }

        let collapsedQuery = collapsed(normalizedQuery)
        return searchableStrings(for: bookmark).contains { value in
            let normalizedValue = normalized(value)
            guard !normalizedValue.isEmpty else { return false }
            if normalizedValue.contains(normalizedQuery) {
                return true
            }

            let pinyinValue = pinyin(normalizedValue)
            return pinyinValue.contains(normalizedQuery)
                || collapsed(pinyinValue).contains(collapsedQuery)
                || initials(from: pinyinValue).contains(collapsedQuery)
        }
    }

    private static func searchableStrings(for bookmark: Bookmark) -> [String] {
        var values = [bookmark.title, bookmark.url]
        if let originalTitle = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !originalTitle.isEmpty,
           originalTitle != bookmark.title {
            values.append(originalTitle)
        }
        return values
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    private static func pinyin(_ value: String) -> String {
        let latin = (value as NSString).applyingTransform(.toLatin, reverse: false) ?? value
        return normalized((latin as NSString).applyingTransform(.stripDiacritics, reverse: false) ?? latin)
    }

    private static func collapsed(_ value: String) -> String {
        value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func initials(from value: String) -> String {
        value
            .split { !$0.isLetter && !$0.isNumber }
            .compactMap(\.first)
            .map(String.init)
            .joined()
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
    let faviconLoader: FaviconLoader
    let addRequest: AddBookmarkRequest
    let onStorageRootChanged: (URL) -> Void
    @State private var selection: Set<Bookmark.ID> = []
    @State private var presentation: Presentation?
    @State private var deleteConfirmation: DeleteConfirmation?
    @State private var refreshAllFaviconConfirmation = false
    @State private var toast: Toast?
    @State private var settingsPage: SettingsPage = .bookmarks
    @State private var selectedCollectionId: UUID?
    @State private var searchText = ""
    @State private var searchFilter: SearchFilter = .all
    @State private var llmProfiles = LLMProfilesSettings()
    @State private var llmConfigMessage: String?
    @State private var isTestingLLMConfig = false
    @State private var hiddenBookmarksUnlocked = false
    @State private var quickLookController = QuickLookController()
    @AppStorage(SidebarIconTheme.storageKey) private var sidebarIconThemeRaw = SidebarIconTheme.colorful.rawValue
    private let sidebarIconTileSize = 22.0
    private let sidebarIconSymbolSize = 11.0
    private let sidebarIconCornerRadius = 6.0
    private let professionalSidebarIconSize = 15.0
    @AppStorage("showHiddenBookmarksPage") private var showHiddenBookmarksPage = false
    @AppStorage("showsURLHostOnly") private var showsURLHostOnly = false
    @AppStorage("menuRecentGroupLimit") private var menuRecentGroupLimit = 5
    @AppStorage(BookmarksModel.autoArchiveEnabledKey) private var autoArchiveEnabled = false
    @AppStorage(BookmarksModel.archiveAfterDaysKey) private var archiveAfterDays = BookmarksModel.defaultArchiveAfterDays
    @AppStorage("windowTransparencyEnabled") private var windowTransparencyEnabled = false
    @AppStorage(ObeliskAppDefaults.openHiddenBookmarksIncognitoKey) private var openHiddenBookmarksIncognito = true
    @AppStorage(HiddenBookmarkKeywordExclusion.storageKey) private var hiddenBookmarkExcludedURLKeywordsRaw = ""
    @AppStorage(TitleOptimizationPreferences.autoOptimizeNewBookmarksKey) private var autoOptimizeNewBookmarks = false
    @AppStorage(TitleOptimizationPreferences.optimizeHiddenBookmarksKey) private var optimizeHiddenBookmarks = false
    @AppStorage(BookmarkAutoGroupingPreferences.autoGroupNewBookmarksKey) private var autoGroupNewBookmarks = false
    @AppStorage(BookmarksModel.aiFeaturesEnabledKey) private var aiFeaturesEnabled = true
    @AppStorage(TitleOptimizationIntensity.storageKey) private var titleOptimizationIntensityRaw = TitleOptimizationIntensity.standard.rawValue
    @AppStorage(TitleOptimizationTranslation.storageKey) private var translateNonChineseTitles = false
    @AppStorage(BookmarkListSortMode.bookmarksStorageKey) private var bookmarkListSortModeRaw = BookmarkListSortMode.name.rawValue
    @AppStorage(BookmarkListSortMode.pinnedStorageKey) private var pinnedBookmarkListSortModeRaw = BookmarkListSortMode.name.rawValue
    @AppStorage(BookmarkListSortMode.collectionsStorageKey) private var collectionListSortModeRaw = BookmarkListSortMode.name.rawValue
    @AppStorage(BookmarkListSortMode.hiddenStorageKey) private var hiddenBookmarkListSortModeRaw = BookmarkListSortMode.name.rawValue
    @AppStorage("bookmarkDisplayMode") private var bookmarkDisplayModeRaw = BookmarkDisplayMode.list.rawValue
    @AppStorage("hiddenBookmarkDisplayMode") private var hiddenBookmarkDisplayModeRaw = BookmarkDisplayMode.list.rawValue
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
    @State private var newHiddenBookmarkExcludedURLKeyword = ""
    @State private var isFetchingOriginalTitles = false
    @State private var pendingAutoIntelligenceTask: Task<Void, Never>?
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
        case search
        case hiddenBookmarks
        case archive
        case appearance
        case menuBar
        case shortcuts
        case ai
        case privacy
        case settings
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
            case .bookmarks, .search, .collections, .hiddenBookmarks, .archive: return .content
            case .appearance, .menuBar, .shortcuts:     return .preferences
            case .ai, .privacy, .settings, .developer:  return .advanced
            }
        }

        var title: String {
            switch self {
            case .bookmarks:       return "书签"
            case .search:          return "搜索"
            case .collections:     return "分组"
            case .hiddenBookmarks: return "隐藏书签"
            case .archive:         return "归档"
            case .appearance:      return "外观"
            case .menuBar:         return "菜单栏"
            case .shortcuts:       return "快捷键"
            case .ai:              return "Intelligence"
            case .privacy:         return "隐私"
            case .settings:        return "设置"
            case .developer:       return "开发者选项"
            }
        }

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
            case .privacy:         return "lock.fill"
            case .settings:        return "gearshape.fill"
            case .developer:       return "wrench.fill"
            }
        }

        var professionalSymbolName: String {
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
            case .privacy:         return "lock.fill"
            case .settings:        return "gearshape.fill"
            case .developer:       return "wrench.fill"
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
            case .privacy:         return "hat-glasses"
            case .settings:        return "settings"
            case .developer:       return "wrench"
            }
        }

        var professionalIconColor: Color {
            switch self {
            case .bookmarks:       return Color(red: 0.00, green: 0.48, blue: 1.00)
            case .search:          return Color(red: 0.00, green: 0.48, blue: 1.00)
            case .collections:     return Color(red: 0.00, green: 0.60, blue: 0.32)
            case .hiddenBookmarks: return Color(red: 0.36, green: 0.34, blue: 0.84)
            case .archive:         return Color(red: 0.00, green: 0.62, blue: 0.72)
            case .appearance:      return Color(red: 0.56, green: 0.18, blue: 0.96)
            case .menuBar:         return Color(red: 0.00, green: 0.58, blue: 0.90)
            case .shortcuts:       return Color(red: 0.12, green: 0.44, blue: 0.86)
            case .ai:              return Color(red: 0.93, green: 0.62, blue: 0.00)
            case .privacy:         return Color(red: 0.36, green: 0.34, blue: 0.84)
            case .settings:        return Color(red: 0.00, green: 0.48, blue: 1.00)
            case .developer:       return Color(red: 0.95, green: 0.43, blue: 0.05)
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
            case .search:
                return LinearGradient(
                    colors: [Color(red: 0.42, green: 0.74, blue: 0.94), Color(red: 0.18, green: 0.46, blue: 0.78)],
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
            case .settings:
                return LinearGradient(
                    colors: [Color(red: 0.52, green: 0.64, blue: 0.78), Color(red: 0.28, green: 0.38, blue: 0.52)],
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

    private var dateGridBookmarkSections: [BookmarkDateSection] {
        BookmarkDateSection.sections(from: visibleBookmarks)
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

    private var hiddenBookmarkDateGridSections: [BookmarkDateSection] {
        BookmarkDateSection.sections(from: hiddenBookmarks)
    }

    private func collectionTitle(for bookmark: Bookmark) -> String? {
        guard let collectionId = model.collectionId(for: bookmark.id) else { return nil }
        return model.collections.first { $0.id == collectionId }?.name
    }

    private var collectionBookmarkSections: [BookmarkListSection] {
        model.visibleCollectionSections(
            sortMode: collectionListSortMode,
            includeEmptyCollections: true,
            showsSortControlOnFirstSection: true
        )
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
            return "全部"
        case .collection(let id):
            return model.collections.first(where: { $0.id == id })?.name ?? "分组"
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
        case .automationPermissionRequired(.accessibility):
            showToast("请在“隐私与安全性 > 辅助功能”允许 Obelisk", kind: .error)
            PermissionSettingsGuide.open(.accessibility)
        case .automationPermissionRequired(.appleEvents):
            showToast("请在“隐私与安全性 > 自动化”允许 Obelisk 控制 Dia", kind: .error)
            PermissionSettingsGuide.open(.automation)
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
        SidebarIconTheme(rawValue: sidebarIconThemeRaw) ?? .colorful
    }

    private var sidebarIconThemeBinding: Binding<SidebarIconTheme> {
        Binding(
            get: { sidebarIconTheme },
            set: { sidebarIconThemeRaw = $0.rawValue }
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
        resetDeveloperOptionsConfirmation = false
        showToast("已恢复开发者选项默认值")
    }

    private func createPlaintextDataBackup() {
        guard developerFeaturesEnabled else {
            showToast("开发者选项已关闭", kind: .error)
            return
        }
        guard !isCreatingPlaintextBackup else { return }

        Task {
            isCreatingPlaintextBackup = true
            guard await AuthenticationGate.authenticate(reason: "导出 Obelisk 明文数据备份") else {
                isCreatingPlaintextBackup = false
                showToast("已取消明文备份", kind: .error)
                return
            }

            guard let destinationParent = choosePlaintextBackupParentDirectory() else {
                isCreatingPlaintextBackup = false
                showToast("已取消明文备份", kind: .error)
                return
            }

            let rootDirectory = model.rootDirectory
            do {
                let result = try await Task.detached(priority: .utility) {
                    try ObeliskPlaintextDataBackup.createBackup(
                        in: rootDirectory,
                        destinationParent: destinationParent
                    )
                }.value
                isCreatingPlaintextBackup = false
                showToast("已备份至 \(result.destinationURL.lastPathComponent)")
            } catch {
                isCreatingPlaintextBackup = false
                showToast(error.localizedDescription, kind: .error)
            }
        }
    }

    private func choosePlaintextBackupParentDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择明文备份位置"
        panel.prompt = "备份"
        panel.message = "将在所选位置创建 Backup-时间戳 文件夹。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
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
            quickLookController.uninstall()
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
        AppKitSettingsSidebar(
            pages: visibleSettingsPages,
            selectedPage: settingsPageBinding,
            badgeCount: sidebarBadgeCount(for:),
            iconTheme: sidebarIconTheme,
            colorfulIconSize: sidebarIconTileSize,
            colorfulSymbolSize: sidebarIconSymbolSize,
            colorfulCornerRadius: sidebarIconCornerRadius,
            professionalIconSize: professionalSidebarIconSize
        )
        .navigationTitle("设置")
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
        case .hiddenBookmarks:
            guard hiddenBookmarksUnlocked else { return nil }
            return hiddenBookmarks.count
        case .archive:
            return archivedBookmarks.count
        default:
            return nil
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
                aiOptimizationPage
            case .privacy:
                privacyPage
            case .settings:
                appSettingsPage
            case .developer:
                developerOptionsPage
            }
        }
        .navigationTitle(settingsPage.title)
    }

    private var bookmarkManagementPage: some View {
        VStack(spacing: 0) {
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
                    Text("点击工具栏的 + 添加你的第一个书签。")
                }
            } else if bookmarkDisplayMode == .dateGrid, visibleBookmarks.isEmpty {
                ContentUnavailableView {
                    Label("没有可见书签", systemImage: "square.grid.2x2")
                } description: {
                    Text("隐藏书签和归档书签不会显示在这里。")
                }
            } else if bookmarkDisplayMode == .dateGrid {
                BookmarkDateGridView(
                    sections: dateGridBookmarkSections,
                    selection: $selection,
                    faviconLoader: faviconLoader,
                    showsURLHostOnly: showsURLHostOnly,
                    collectionTitle: { bookmark in collectionTitle(for: bookmark) },
                    onOpen: { bookmark in openBookmark(bookmark) },
                    onCopyURL: { bookmark in copyURL(bookmark) },
                    onRefreshFavicon: { bookmark in refreshFavicon(for: bookmark) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    onSetHidden: { bookmark in setHidden(true, for: bookmark) },
                    hiddenStateActionTitle: "移到隐藏书签",
                    onSetArchived: { bookmark in setArchived(true, for: bookmark) },
                    pinStateActionTitle: { $0.isPinned ? "取消置顶" : "置顶" },
                    onSetPinned: { bookmark in setPinned(!bookmark.isPinned, for: bookmark) },
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: { bookmarkIds, collectionId in
                        assignCollection(bookmarkIds: bookmarkIds, collectionId: collectionId)
                    }
                )
            } else if bookmarkSections.isEmpty {
                ContentUnavailableView {
                    Label("没有未分组的书签", systemImage: "bookmark")
                } description: {
                    Text("已放入分组的书签在「分组」页查看。")
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
                    archiveStateActionTitle: "归档",
                    onSetArchived: { bookmark in setArchived(true, for: bookmark) },
                    pinStateActionTitle: { $0.isPinned ? "取消置顶" : "置顶" },
                    onSetPinned: { bookmark in setPinned(!bookmark.isPinned, for: bookmark) },
                    onSortModeChange: { sortMode, scope in
                        updateBookmarkListSortMode(sortMode, scope: scope)
                    },
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

            if bookmarkDisplayMode == .dateGrid {
                Text("\(visibleBookmarks.count) 个书签")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
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

            if hiddenBookmarkDisplayMode == .dateGrid {
                Text("\(hiddenBookmarks.count) 个书签")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var searchPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeSearchField(text: $searchText, placeholder: "搜索")
                .frame(height: 34)
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
                    onOpen: { bookmark in openBookmark(bookmark) },
                    onCopyURL: { bookmark in copyURL(bookmark) },
                    onRefreshFavicon: { bookmark in refreshFavicon(for: bookmark) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "移到隐藏书签",
                    onSetHidden: { bookmark in setHidden(true, for: bookmark) },
                    archiveStateActionTitleProvider: { bookmark in
                        model.isEffectivelyArchived(bookmark) ? "恢复到书签" : "归档"
                    },
                    onSetArchived: { bookmark in setArchived(!model.isEffectivelyArchived(bookmark), for: bookmark) },
                    pinStateActionTitle: { $0.isPinned ? "取消置顶" : "置顶" },
                    onSetPinned: { bookmark in setPinned(!bookmark.isPinned, for: bookmark) },
                    collectionAssignOptions: collectionAssignOptions,
                    onAssignCollection: { bookmarkIds, collectionId in
                        assignCollection(bookmarkIds: bookmarkIds, collectionId: collectionId)
                    },
                    onRevertTitleOptimization: { bookmarkIds in revertTitleOptimizations(bookmarkIds: bookmarkIds) }
                )
            }
        }
        .navigationTitle("搜索")
    }

    private var collectionsManagementPage: some View {
        Group {
            if model.collections.isEmpty {
                ContentUnavailableView {
                    Label("还没有分组", systemImage: "folder")
                } description: {
                    Text("点击工具栏 + 创建分组。")
                }
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
                    onOpen: { bookmark in openBookmark(bookmark) },
                    onCopyURL: { bookmark in copyURL(bookmark) },
                    onRefreshFavicon: { bookmark in refreshFavicon(for: bookmark) },
                    onEdit: { bookmark in presentation = .edit(bookmark) },
                    onDelete: { ids in requestDelete(ids: ids) },
                    hiddenStateActionTitle: "移到隐藏书签",
                    onSetHidden: { bookmark in setHidden(true, for: bookmark) },
                    archiveStateActionTitle: "归档",
                    onSetArchived: { bookmark in setArchived(true, for: bookmark) },
                    pinStateActionTitle: { $0.isPinned ? "取消置顶" : "置顶" },
                    onSetPinned: { bookmark in setPinned(!bookmark.isPinned, for: bookmark) },
                    onSortModeChange: { sortMode, _ in collectionListSortMode = sortMode },
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
            } else if hiddenBookmarkDisplayMode == .dateGrid {
                VStack(spacing: 0) {
                    hiddenBookmarkDisplayModePicker
                        .padding(.leading, 0)
                        .padding(.trailing, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    BookmarkDateGridView(
                        sections: hiddenBookmarkDateGridSections,
                        selection: $selection,
                        faviconLoader: faviconLoader,
                        showsURLHostOnly: showsURLHostOnly,
                        collectionTitle: { bookmark in collectionTitle(for: bookmark) },
                        onOpen: { bookmark in openHiddenBookmark(bookmark) },
                        onCopyURL: { bookmark in copyURL(bookmark) },
                        onRefreshFavicon: { bookmark in refreshFavicon(for: bookmark) },
                        onEdit: { bookmark in presentation = .edit(bookmark) },
                        onDelete: { ids in requestDelete(ids: ids) },
                        onSetHidden: { bookmark in setHidden(false, for: bookmark) },
                        hiddenStateActionTitle: "恢复到书签",
                        onSetArchived: { bookmark in setArchived(true, for: bookmark) },
                        pinStateActionTitle: { $0.isPinned ? "取消置顶" : "置顶" },
                        onSetPinned: { bookmark in setPinned(!bookmark.isPinned, for: bookmark) },
                        collectionAssignOptions: collectionAssignOptions,
                        onAssignCollection: { bookmarkIds, collectionId in
                            assignCollection(bookmarkIds: bookmarkIds, collectionId: collectionId)
                        }
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

            if archivedBookmarks.isEmpty {
                ContentUnavailableView {
                    Label("没有归档书签", systemImage: "archivebox")
                } description: {
                    if autoArchiveEnabled {
                        Text("闲置书签会在达到设定天数后自动归档。")
                    } else {
                        Text("您手动归档的书签会显示在这里。")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("归档")
    }

    private var appearancePage: some View {
        Form {
            Section("主题") {
                LabeledContent("主题") {
                    Picker("主题", selection: sidebarIconThemeBinding) {
                        ForEach(SidebarIconTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
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
                        Text("为 Obelisk 窗口启用毛玻璃半透明材质。")
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
                menuLimitStepper("最近添加数量", desc: "Obelisk「最近添加」最多显示的书签数量。", value: $menuRecentGroupLimit)
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
                ShortcutRecorderRow(title: "添加书签", name: .addBookmark)
                ShortcutRecorderRow(title: "添加隐藏书签", name: .addHiddenBookmark)
                ShortcutRecorderRow(title: "菜单栏搜索", name: .menuBarSearch)
                ShortcutRecorderRow(
                    title: "撤销添加",
                    description: "添加书签 5s 内可以撤回。",
                    name: .undoAdd
                )
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
                Section("Intelligence 书签优化") {
                    LabeledContent {
                        titleIntensityPicker
                            // SwiftUI gives this picker a larger trailing inset
                            // than the model source row; keep the chevrons aligned.
                            .padding(.trailing, -12)
                    } label: {
                        Text("优化程度")
                    }

                    Toggle(isOn: $autoOptimizeNewBookmarks) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动优化新书签标题")
                            Text("开启后将自动使用配置的模型优化新添加的书签标题。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $autoGroupNewBookmarks) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动分组新书签")
                            Text("开启后将自动使用配置的模型把新添加的可见书签归入合适分组。")
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

    private var appSettingsPage: some View {
        Form {
            Section("启动") {
                Toggle("在登录时启动 Obelisk", isOn: launchAtLoginBinding)
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

    private var privacyPage: some View {
        Form {
            Section("隐藏书签") {
                Toggle("在侧边栏显示隐藏书签", isOn: $showHiddenBookmarksPage)

                Toggle(isOn: $openHiddenBookmarksIncognito) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("使用无痕窗口打开隐藏书签")
                        Text("Dia 会复用 Obelisk 创建的无痕窗口；其他 Chromium 浏览器使用启动参数。")
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

                    Text("包含关键字的 URL 只能添加到「隐藏书签」。")
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

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusesOnAppear = false
    var focusRequest = 0
    var onEscape: (() -> Void)?
    var onTab: (() -> Void)?
    var onEnter: ((String) -> Void)?
    var onDownArrow: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onEscape: onEscape,
            onTab: onTab,
            onEnter: onEnter,
            onDownArrow: onDownArrow
        )
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = FocusableSearchField()
        searchField.focusesOnAppear = focusesOnAppear
        searchField.focusRequest = focusRequest
        searchField.onEscape = onEscape
        searchField.onTab = onTab
        searchField.onEnter = onEnter
        searchField.onDownArrow = onDownArrow
        searchField.placeholderString = placeholder
        searchField.delegate = context.coordinator
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: NSFont.systemFontSize)
        searchField.bezelStyle = .roundedBezel
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.searchFieldAction(_:))
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        if let searchField = searchField as? FocusableSearchField {
            searchField.focusesOnAppear = focusesOnAppear
            searchField.focusRequest = focusRequest
            searchField.onEscape = onEscape
            searchField.onTab = onTab
            searchField.onEnter = onEnter
            searchField.onDownArrow = onDownArrow
            searchField.focusIfNeeded()
        }
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
        searchField.placeholderString = placeholder
        context.coordinator.text = $text
        context.coordinator.onEscape = onEscape
        context.coordinator.onTab = onTab
        context.coordinator.onEnter = onEnter
        context.coordinator.onDownArrow = onDownArrow
    }

    private final class FocusableSearchField: NSSearchField {
        var focusesOnAppear = false
        var onEscape: (() -> Void)?
        var onTab: (() -> Void)?
        var onEnter: ((String) -> Void)?
        var onDownArrow: (() -> Void)?
        var focusRequest = 0
        private var didFocus = false
        private var handledFocusRequest = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusIfNeeded()
        }

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.numericPad)
            guard modifiers.isEmpty else {
                super.keyDown(with: event)
                return
            }

            switch event.keyCode {
            case UInt16(kVK_Escape):
                guard let onEscape else { break }
                onEscape()
                return
            case UInt16(kVK_Tab):
                guard let onTab else { break }
                onTab()
                return
            case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
                guard let onEnter else { break }
                onEnter(stringValue)
                return
            case UInt16(kVK_DownArrow):
                guard let onDownArrow else { break }
                onDownArrow()
                return
            default:
                break
            }

            super.keyDown(with: event)
        }

        func focusIfNeeded() {
            guard window != nil else { return }
            let shouldFocusOnAppear = focusesOnAppear && !didFocus
            let shouldFocusForRequest = focusRequest > 0 && focusRequest != handledFocusRequest
            guard shouldFocusOnAppear || shouldFocusForRequest else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                let shouldFocusOnAppear = self.focusesOnAppear && !self.didFocus
                let shouldFocusForRequest = self.focusRequest > 0 &&
                    self.focusRequest != self.handledFocusRequest
                guard shouldFocusOnAppear || shouldFocusForRequest else { return }

                window.makeKey()
                if window.makeFirstResponder(self) {
                    self.didFocus = true
                    if self.focusRequest > 0 {
                        self.handledFocusRequest = self.focusRequest
                    }
                }
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onEscape: (() -> Void)?
        var onTab: (() -> Void)?
        var onEnter: ((String) -> Void)?
        var onDownArrow: (() -> Void)?

        init(
            text: Binding<String>,
            onEscape: (() -> Void)?,
            onTab: (() -> Void)?,
            onEnter: ((String) -> Void)?,
            onDownArrow: (() -> Void)?
        ) {
            self.text = text
            self.onEscape = onEscape
            self.onTab = onTab
            self.onEnter = onEnter
            self.onDownArrow = onDownArrow
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            text.wrappedValue = searchField.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            text.wrappedValue = textView.string
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                onEscape?()
                return true
            case #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertTabIgnoringFieldEditor(_:)):
                guard let onTab else { return false }
                onTab()
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                guard let onEnter else { return false }
                onEnter(textView.string)
                return true
            case #selector(NSResponder.moveDown(_:)):
                guard let onDownArrow else { return false }
                onDownArrow()
                return true
            default:
                return false
            }
        }

        @MainActor @objc func searchFieldAction(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
            guard let event = NSApp.currentEvent, event.type == .keyDown else { return }
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.numericPad)
            guard modifiers.isEmpty else { return }
            if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                onEnter?(sender.stringValue)
            }
        }
    }
}

private extension View {
    func settingsContentMargins() -> some View {
        self
            .contentMargins(.horizontal, 18, for: .scrollContent)
            .contentMargins(.top, 0, for: .scrollContent)
    }
}

private struct BookmarkDateSection: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let bookmarks: [Bookmark]

    static func sections(from bookmarks: [Bookmark], calendar: Calendar = .current) -> [BookmarkDateSection] {
        let sorted = bookmarks.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        let grouped = Dictionary(grouping: sorted) { bookmark -> Date? in
            guard bookmark.createdAt > .distantPast else { return nil }
            return calendar.startOfDay(for: bookmark.createdAt)
        }

        let datedSections = grouped.keys.compactMap { $0 }.sorted(by: >).compactMap { day -> BookmarkDateSection? in
            guard let bookmarks = grouped[day], !bookmarks.isEmpty else { return nil }
            return BookmarkDateSection(
                id: "day-\(day.timeIntervalSinceReferenceDate)",
                title: title(for: day, calendar: calendar),
                subtitle: "\(bookmarks.count) 个书签",
                bookmarks: bookmarks
            )
        }

        let unknownBookmarks = grouped[nil] ?? []
        guard !unknownBookmarks.isEmpty else { return datedSections }
        return datedSections + [
            BookmarkDateSection(
                id: "unknown",
                title: "未知日期",
                subtitle: "\(unknownBookmarks.count) 个书签",
                bookmarks: unknownBookmarks
            )
        ]
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        let now = Date()
        if calendar.isDateInToday(day) {
            return "今天"
        }
        if calendar.isDateInYesterday(day) {
            return "昨天"
        }

        let formatter = DateFormatter()
        formatter.locale = .current
        if calendar.component(.year, from: day) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("MMMdEEE")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("yMMMdEEE")
        }
        return formatter.string(from: day)
    }
}

private struct BookmarkDateGridView: View {
    let sections: [BookmarkDateSection]
    @Binding var selection: Set<Bookmark.ID>
    let faviconLoader: FaviconLoader
    let showsURLHostOnly: Bool
    let collectionTitle: (Bookmark) -> String?
    let onOpen: (Bookmark) -> Void
    let onCopyURL: (Bookmark) -> Void
    let onRefreshFavicon: (Bookmark) -> Void
    let onEdit: (Bookmark) -> Void
    let onDelete: (Set<Bookmark.ID>) -> Void
    let onSetHidden: (Bookmark) -> Void
    let hiddenStateActionTitle: String
    let onSetArchived: (Bookmark) -> Void
    let pinStateActionTitle: (Bookmark) -> String
    let onSetPinned: (Bookmark) -> Void
    let collectionAssignOptions: [BookmarkCollectionAssignOption]
    let onAssignCollection: (Set<Bookmark.ID>, UUID?) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 168, maximum: 224), spacing: 12, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(section.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(section.subtitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }

                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(section.bookmarks) { bookmark in
                                BookmarkGridCard(
                                    bookmark: bookmark,
                                    isSelected: selection.contains(bookmark.id),
                                    faviconLoader: faviconLoader,
                                    showsURLHostOnly: showsURLHostOnly,
                                    collectionTitle: collectionTitle(bookmark),
                                    onSelect: {
                                        selection = [bookmark.id]
                                    },
                                    onOpen: {
                                        onOpen(bookmark)
                                    },
                                    onCopyURL: {
                                        onCopyURL(bookmark)
                                    },
                                    onRefreshFavicon: {
                                        onRefreshFavicon(bookmark)
                                    },
                                    onEdit: {
                                        onEdit(bookmark)
                                    },
                                    onDelete: {
                                        onDelete([bookmark.id])
                                    },
                                    onSetHidden: {
                                        onSetHidden(bookmark)
                                    },
                                    hiddenStateActionTitle: hiddenStateActionTitle,
                                    onSetArchived: {
                                        onSetArchived(bookmark)
                                    },
                                    pinStateActionTitle: pinStateActionTitle(bookmark),
                                    onSetPinned: {
                                        onSetPinned(bookmark)
                                    },
                                    collectionAssignOptions: collectionAssignOptions,
                                    onAssignCollection: { collectionId in
                                        onAssignCollection([bookmark.id], collectionId)
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 20)
        }
    }
}

private struct BookmarkGridCard: View {
    let bookmark: Bookmark
    let isSelected: Bool
    let faviconLoader: FaviconLoader
    let showsURLHostOnly: Bool
    let collectionTitle: String?
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onCopyURL: () -> Void
    let onRefreshFavicon: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSetHidden: () -> Void
    let hiddenStateActionTitle: String
    let onSetArchived: () -> Void
    let pinStateActionTitle: String
    let onSetPinned: () -> Void
    let collectionAssignOptions: [BookmarkCollectionAssignOption]
    let onAssignCollection: (UUID?) -> Void

    @State private var isPressed = false
    @AppStorage("windowTransparencyEnabled") private var windowTransparencyEnabled = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let _ = faviconLoader.version
        let favicon = faviconLoader.image(for: bookmark.url)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                faviconView(favicon)

                Spacer(minLength: 0)

                if bookmark.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                        .padding(6)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(bookmark.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(displayURL)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if let collectionTitle {
                cardPill(collectionTitle)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .padding(10)
        .background(cardBackground)
        .overlay(cardBorder)
        .scaleEffect(isPressed ? 0.985 : 1)
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            onSelect()
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onOpen()
            }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .contextMenu {
            Button("打开", action: onOpen)
            Button("复制 URL", action: onCopyURL)
            Button("刷新 Favicon", action: onRefreshFavicon)
            Button("编辑", action: onEdit)
            Divider()
            Button(pinStateActionTitle, action: onSetPinned)
            if !collectionAssignOptions.isEmpty {
                Menu("移到分组") {
                    ForEach(collectionAssignOptions, id: \.title) { option in
                        Button(option.title) {
                            onAssignCollection(option.collectionId)
                        }
                    }
                }
            }
            Button(hiddenStateActionTitle, action: onSetHidden)
            Button("归档", action: onSetArchived)
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bookmark.title)
    }

    private var cardBackgroundColor: Color {
        switch colorScheme {
        case .dark:
            return Color(red: 39 / 255, green: 41 / 255, blue: 54 / 255)
        default:
            return Color(red: 247 / 255, green: 247 / 255, blue: 247 / 255)
        }
    }

    private var cardTransparentBackgroundColor: Color {
        switch colorScheme {
        case .dark:
            return Color.white.opacity(0.04)
        default:
            return Color.black.opacity(0.04)
        }
    }

    private var cardBackground: some View {
        let fill: Color
        if windowTransparencyEnabled {
            fill = isSelected ? Color.accentColor.opacity(0.20) : cardTransparentBackgroundColor
        } else {
            fill = isSelected ? Color.accentColor.opacity(0.14) : cardBackgroundColor
        }
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(fill)
            .shadow(
                color: .black.opacity(isSelected ? 0.12 : 0.07),
                radius: isSelected ? 8 : 4,
                y: isSelected ? 4 : 2
            )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(
                isSelected ? Color.accentColor.opacity(0.75) : Color(nsColor: .separatorColor).opacity(0.42),
                lineWidth: isSelected ? 1.4 : 1
            )
    }

    private var displayURL: String {
        guard showsURLHostOnly, let host = URL(string: bookmark.url)?.host(percentEncoded: false) else {
            return bookmark.url
        }
        return host
    }

    private func faviconView(_ favicon: NSImage?) -> some View {
        Group {
            if let favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(nsImage: AppIcon.faviconPlaceholder(size: NSSize(width: 24, height: 24)))
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: 24, height: 24)
    }

    private func cardPill(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
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
    var onBookmarkAdded: ((Bookmark) -> Void)?
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
        switch mode {
        case .add:
            switch model.addBookmark(title: title, url: url, isHidden: isHidden) {
            case .success(let bookmark):
                onBookmarkAdded?(bookmark)
                dismiss()
            case .failure(let error):
                commitErrorMessage = error.localizedDescription
            }
        case .edit(let bookmark):
            var updated = bookmark
            updated.title = title
            updated.url = url
            updated.isHidden = isHidden
            if let errorMessage = model.update(updated) {
                commitErrorMessage = errorMessage
            } else {
                dismiss()
            }
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
                Text("将把开发者选项恢复为默认状态，不会修改书签数据。")
            }
    }
}
