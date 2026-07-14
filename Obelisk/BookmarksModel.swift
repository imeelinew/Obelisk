import AppKit
import Foundation
import ObeliskCore
import ObeliskData
import Observation

enum BookmarkMenuSectionID: Hashable, Identifiable {
    case pinned
    case recent
    case browserHistory
    case collection(UUID)
    case ungrouped

    var id: String { storageValue }

    var storageValue: String {
        switch self {
        case .pinned: return "pinned"
        case .recent: return "recent"
        case .browserHistory: return "browserHistory"
        case .collection(let id): return "collection:\(id.uuidString)"
        case .ungrouped: return "ungrouped"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "pinned":
            self = .pinned
        case "recent":
            self = .recent
        case "browserHistory":
            self = .browserHistory
        case "ungrouped":
            self = .ungrouped
        default:
            guard
                storageValue.hasPrefix("collection:"),
                let id = UUID(uuidString: String(storageValue.dropFirst("collection:".count)))
            else {
                return nil
            }
            self = .collection(id)
        }
    }
}

struct BookmarkMenuOrderItem: Identifiable {
    var id: BookmarkMenuSectionID
    var title: String
    var systemImage: String
}

enum BookmarkMenuSectionOrder {
    static let storageKey = "menuBarSectionOrder"

    static func encoded(_ ids: [BookmarkMenuSectionID]) -> String {
        ids.map(\.storageValue).joined(separator: "\n")
    }

    static func order(
        collections: [BookmarkCollection],
        rawValue: String? = UserDefaults.standard.string(forKey: storageKey)
    ) -> [BookmarkMenuSectionID] {
        let defaultOrder = defaultOrder(collections: collections)
        guard let rawValue, !rawValue.isEmpty else {
            return defaultOrder
        }

        let validCollectionIds = Set(collections.map(\.id))
        var seen = Set<BookmarkMenuSectionID>()
        var result: [BookmarkMenuSectionID] = []
        for id in rawValue.split(separator: "\n").compactMap({ BookmarkMenuSectionID(storageValue: String($0)) }) {
            guard isValid(id, validCollectionIds: validCollectionIds), !seen.contains(id) else {
                continue
            }
            result.append(id)
            seen.insert(id)
        }

        insertMissingStaticItems(into: &result)

        let missingCollections = collections
            .map { BookmarkMenuSectionID.collection($0.id) }
            .filter { !seen.contains($0) && !result.contains($0) }
        let insertionIndex = collectionInsertionIndex(in: result)
        result.insert(contentsOf: missingCollections, at: insertionIndex)

        return result
    }

    static func items(
        collections: [BookmarkCollection],
        rawValue: String? = UserDefaults.standard.string(forKey: storageKey)
    ) -> [BookmarkMenuOrderItem] {
        let collectionNames = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0.name) })
        return order(collections: collections, rawValue: rawValue).map { id in
            switch id {
            case .pinned:
                return BookmarkMenuOrderItem(id: id, title: "置顶", systemImage: "pin.fill")
            case .recent:
                return BookmarkMenuOrderItem(id: id, title: "最近添加", systemImage: "clock.arrow.circlepath")
            case .browserHistory:
                return BookmarkMenuOrderItem(id: id, title: "最近浏览", systemImage: "clock.fill")
            case .collection(let collectionId):
                return BookmarkMenuOrderItem(
                    id: id,
                    title: collectionNames[collectionId] ?? "分组",
                    systemImage: "folder.fill"
                )
            case .ungrouped:
                return BookmarkMenuOrderItem(id: id, title: "未分组", systemImage: "bookmark.fill")
            }
        }
    }

    private static func defaultOrder(collections: [BookmarkCollection]) -> [BookmarkMenuSectionID] {
        [.pinned, .recent, .browserHistory] + collections.map { .collection($0.id) } + [.ungrouped]
    }

    private static func isValid(_ id: BookmarkMenuSectionID, validCollectionIds: Set<UUID>) -> Bool {
        switch id {
        case .pinned, .recent, .browserHistory, .ungrouped:
            return true
        case .collection(let collectionId):
            return validCollectionIds.contains(collectionId)
        }
    }

    private static func insertMissingStaticItems(into result: inout [BookmarkMenuSectionID]) {
        if !result.contains(.pinned) {
            result.insert(.pinned, at: 0)
        }
        if !result.contains(.recent) {
            let index = result.firstIndex(of: .pinned).map { $0 + 1 } ?? 0
            result.insert(.recent, at: min(index, result.count))
        }
        if !result.contains(.browserHistory) {
            let index = result.firstIndex(of: .recent).map { $0 + 1 } ?? 0
            result.insert(.browserHistory, at: min(index, result.count))
        }
        if !result.contains(.ungrouped) {
            result.append(.ungrouped)
        }
    }

    private static func collectionInsertionIndex(in result: [BookmarkMenuSectionID]) -> Int {
        if let recentIndex = result.firstIndex(of: .recent),
           let ungroupedIndex = result.firstIndex(of: .ungrouped),
           recentIndex < ungroupedIndex {
            return ungroupedIndex
        }
        if let recentIndex = result.firstIndex(of: .recent) {
            return min(recentIndex + 1, result.count)
        }
        return result.firstIndex(of: .ungrouped) ?? result.count
    }
}

struct BookmarkMenuRenderSection: Identifiable {
    enum Presentation {
        case inline
        case reference
        case submenu
    }

    var id: BookmarkMenuSectionID
    var title: String
    var bookmarks: [Bookmark]
    var presentation: Presentation
}

struct BookmarkMenuSections {
    var pinned: [BookmarkListSection]
    var recent: [Bookmark]
    var collections: [BookmarkListSection]
    var ungrouped: [BookmarkListSection]

    var library: [BookmarkListSection] {
        collections + ungrouped
    }

    var isEmpty: Bool {
        pinned.isEmpty && recent.isEmpty && collections.isEmpty && ungrouped.isEmpty
    }

    func renderSections(order: [BookmarkMenuSectionID]) -> [BookmarkMenuRenderSection] {
        let collectionSections = Dictionary(
            uniqueKeysWithValues: collections.compactMap { section -> (UUID, BookmarkListSection)? in
                guard let collectionId = section.collectionId else { return nil }
                return (collectionId, section)
            }
        )

        return order.compactMap { id in
            switch id {
            case .pinned:
                guard let section = pinned.first, let title = section.title, !section.bookmarks.isEmpty else {
                    return nil
                }
                return BookmarkMenuRenderSection(
                    id: id,
                    title: title,
                    bookmarks: section.bookmarks,
                    presentation: .inline
                )
            case .recent:
                guard !recent.isEmpty else { return nil }
                return BookmarkMenuRenderSection(
                    id: id,
                    title: "最近添加 (\(recent.count))",
                    bookmarks: recent,
                    presentation: .reference
                )
            case .browserHistory:
                return nil
            case .collection(let collectionId):
                guard
                    let section = collectionSections[collectionId],
                    let title = section.title,
                    !section.bookmarks.isEmpty
                else {
                    return nil
                }
                return BookmarkMenuRenderSection(
                    id: id,
                    title: title,
                    bookmarks: section.bookmarks,
                    presentation: .submenu
                )
            case .ungrouped:
                guard let section = ungrouped.first, let title = section.title, !section.bookmarks.isEmpty else {
                    return nil
                }
                return BookmarkMenuRenderSection(
                    id: id,
                    title: title,
                    bookmarks: section.bookmarks,
                    presentation: .submenu
                )
            }
        }
    }
}

struct TitleOptimizationOutcome: Equatable {
    enum Status: Equatable {
        case changed
        case noChange
        case failed
    }

    var message: String
    var optimizedTitles: [String]
    var status: Status = .noChange
}

struct AutoGroupedBookmarkPlacement: Equatable {
    var bookmarkId: UUID
    var groupName: String
}

struct BookmarkAutoGroupingOutcome: Equatable {
    enum Status: Equatable {
        case changed
        case noChange
        case failed
    }

    var message: String
    var groupedCount: Int
    var placements: [AutoGroupedBookmarkPlacement]
    var status: Status = .noChange

    var singleBookmarkDescription: String? {
        guard placements.count == 1, let placement = placements.first else {
            return nil
        }
        return "已归入「\(placement.groupName)」"
    }
}

struct BookmarkIntelligenceOptimizationOptions: Equatable {
    var optimizeTitles: Bool
    var autoGroup: Bool

    static func automatic(
        for bookmark: Bookmark,
        defaults: UserDefaults = .standard
    ) -> Self {
        Self(
            optimizeTitles: TitleOptimizationPreferences.allowsAutoOptimization(
                for: bookmark,
                defaults: defaults
            ),
            autoGroup: BookmarkAutoGroupingPreferences.autoGroupNewBookmarks(in: defaults)
                && !bookmark.isHidden
        )
    }
}

struct BookmarkIntelligenceOptimizationOutcome: Equatable {
    var titleOptimization: TitleOptimizationOutcome?
    var autoGrouping: BookmarkAutoGroupingOutcome?

    var didChange: Bool {
        titleOptimization?.status == .changed || autoGrouping?.status == .changed
    }

    var summary: String {
        let parts = [
            titleOptimization.map(Self.titleSummary),
            autoGrouping.map(Self.groupingSummary)
        ].compactMap { $0 }

        return parts.isEmpty ? "没有启用书签优化项目" : parts.joined(separator: "；")
    }

    private static func titleSummary(_ outcome: TitleOptimizationOutcome) -> String {
        if outcome.status == .changed {
            if outcome.optimizedTitles.count == 1, let title = outcome.optimizedTitles.first {
                return "标题「\(title)」"
            }
            return "优化标题 \(outcome.optimizedTitles.count) 个"
        }
        return outcome.message
    }

    private static func groupingSummary(_ outcome: BookmarkAutoGroupingOutcome) -> String {
        if outcome.status == .changed {
            return outcome.singleBookmarkDescription ?? "自动分组 \(outcome.groupedCount) 个"
        }
        return outcome.message
    }
}

private struct BookmarkValidationError: LocalizedError {
    var message: String

    var errorDescription: String? {
        message
    }
}

@MainActor
@Observable
final class BookmarksModel {
    static let autoArchiveEnabledKey = "autoArchiveIdleBookmarks"
    static let archiveAfterDaysKey = "archiveAfterDays"
    static let aiFeaturesEnabledKey = "aiFeaturesEnabled"
    static let minArchiveAfterDays = 3
    static let maxArchiveAfterDays = 30
    static let defaultArchiveAfterDays = 30
    private static let autoArchiveFrequentProtectionLimit = 5

    private(set) var bookmarks: [Bookmark] = []
    /// Top-N by createdAt, excluding pinned items.
    private(set) var recent: [Bookmark] = []
    /// User-pinned visible bookmarks. These are excluded from the smart
    /// spotlight and library sections so they only appear in the pinned group.
    private(set) var pinned: [Bookmark] = []
    /// Bookmarks not shown in menu spotlight.
    private(set) var others: [Bookmark] = []
    /// User-defined collections, sorted by `sortOrder` then name.
    private(set) var collections: [BookmarkCollection] = []
    private var membershipByBookmarkId: [UUID: UUID] = [:]
    private var usageByBookmarkId: [UUID: UsageRecord] = [:]
    private var searchIndex = BookmarkSearchIndex(bookmarks: [])
    private var visibleBookmarksSnapshot: [Bookmark] = []
    var errorMessage: String?
    private(set) var loadErrorMessage: String?

    /// Fired whenever the model's published state changes (reload or open).
    /// AppDelegate uses this to drive menubar rebuilds so menubar and the
    /// manage window stay in sync without recomputing groups twice.
    @ObservationIgnored var onChange: (() -> Void)?

    private let store: BookmarkStore
    private let titleOptimizer: any TitleOptimizing
    private let groupOptimizer: any BookmarkGroupingOptimizing
    private var recentGroupLimit: Int
    private(set) var isOptimizingTitles = false
    private(set) var isAutoGroupingBookmarks = false
    private(set) var isOptimizingBookmarks = false

    var rootDirectory: URL {
        store.rootDirectory
    }

    func collectionId(for bookmarkId: UUID) -> UUID? {
        membershipByBookmarkId[bookmarkId]
    }

    func notifyMenuPresentationChanged() {
        onChange?()
    }

    private var autoArchiveEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.autoArchiveEnabledKey)
    }

    private var archiveAfterDays: Int {
        let value = UserDefaults.standard.object(forKey: Self.archiveAfterDaysKey) as? Int
        return Self.clampedArchiveAfterDays(value ?? Self.defaultArchiveAfterDays)
    }

    static func clampedArchiveAfterDays(_ value: Int) -> Int {
        min(maxArchiveAfterDays, max(minArchiveAfterDays, value))
    }

    init(
        store: BookmarkStore,
        recentGroupLimit: Int = 5,
        titleOptimizer: (any TitleOptimizing)? = nil,
        groupOptimizer: (any BookmarkGroupingOptimizing)? = nil
    ) {
        self.store = store
        let defaultOptimizer = TitleOptimizer()
        self.titleOptimizer = titleOptimizer ?? defaultOptimizer
        self.groupOptimizer = groupOptimizer ?? defaultOptimizer
        self.recentGroupLimit = recentGroupLimit
        reload()
    }

    func reload() {
        do {
            let snapshot = try store.snapshot()
            let all = snapshot.bookmarks
            let usage = snapshot.usageByBookmarkID
            usageByBookmarkId = usage
            bookmarks = all
            searchIndex = BookmarkSearchIndex(bookmarks: all)
            collections = snapshot.collections.sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            membershipByBookmarkId = Self.prunedMembership(
                snapshot.collectionByBookmarkID,
                collections: collections,
                bookmarkIds: Set(all.map(\.id))
            )
            let visibleBookmarks = visibleBookmarks(from: all, usage: usage)
            visibleBookmarksSnapshot = visibleBookmarks
            pinned = BookmarkListSortMode.storedForPinned.sorted(visibleBookmarks.filter(\.isPinned), usage: usage)
            recomputeMenuSpotlight(from: visibleBookmarks, usage: usage)
            let priorLoadError = loadErrorMessage
            loadErrorMessage = nil
            if errorMessage == priorLoadError {
                errorMessage = nil
            }
            onChange?()
        } catch {
            let message = error.localizedDescription
            loadErrorMessage = message
            errorMessage = message
            onChange?()
        }
    }

    @discardableResult
    func applyAutoArchiveIfNeeded() -> Bool {
        let priorRecent = recent.map(\.id)
        let priorOthers = others.map(\.id)
        let priorPinned = pinned.map(\.id)

        let usage = usageByBookmarkId
        let visibleBookmarks = visibleBookmarks(from: bookmarks, usage: usage)
        visibleBookmarksSnapshot = visibleBookmarks
        pinned = BookmarkListSortMode.storedForPinned.sorted(visibleBookmarks.filter(\.isPinned), usage: usage)
        recomputeMenuSpotlight(from: visibleBookmarks, usage: usage)

        let changed = recent.map(\.id) != priorRecent
            || others.map(\.id) != priorOthers
            || pinned.map(\.id) != priorPinned
        if changed {
            onChange?()
        }
        return changed
    }

    /// Returns nil on success, or a localized error message on failure.
    /// We deliberately do NOT mutate `errorMessage` here — that property is
    /// the parent view's alert binding, and the editor sheet covering it
    /// would suppress the alert until the sheet dismisses (i.e. user clicks
    /// "取消"), making the alert show at the wrong time. The editor handles
    /// the returned message inline / via its own alert.
    func add(title: String, url: String, isHidden: Bool = false) -> String? {
        switch addBookmark(title: title, url: url, isHidden: isHidden) {
        case .success:
            return nil
        case .failure(let error):
            return error.localizedDescription
        }
    }

    func addBookmark(title: String, url: String, isHidden: Bool = false) -> Result<Bookmark, Error> {
        do {
            guard isHidden || !HiddenBookmarkKeywordExclusion.matches(url: url) else {
                return .failure(BookmarkValidationError(message: HiddenBookmarkKeywordExclusion.blockedBookmarkMessage))
            }
            let bookmark = try store.add(title: title, url: url, isHidden: isHidden)
            reload()
            return .success(bookmark)
        } catch {
            return .failure(error)
        }
    }

    func update(_ bookmark: Bookmark) -> String? {
        do {
            if !bookmark.isHidden, HiddenBookmarkKeywordExclusion.matches(url: bookmark.url) {
                return HiddenBookmarkKeywordExclusion.blockedBookmarkMessage
            }
            try store.update(bookmark)
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setHidden(_ isHidden: Bool, for id: UUID) -> String? {
        guard var bookmark = bookmarks.first(where: { $0.id == id }) else {
            return "找不到这个书签"
        }
        guard bookmark.isHidden != isHidden else {
            return nil
        }
        if !isHidden, HiddenBookmarkKeywordExclusion.matches(url: bookmark.url) {
            return HiddenBookmarkKeywordExclusion.blockedBookmarkMessage
        }
        bookmark.isHidden = isHidden
        return update(bookmark)
    }

    func setArchived(_ isArchived: Bool, for id: UUID) -> String? {
        do {
            try store.setArchived(isArchived, ids: [id])
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setPinned(_ isPinned: Bool, for id: UUID) -> String? {
        setPinned(isPinned, for: [id])
    }

    func setPinned(_ isPinned: Bool, for ids: Set<UUID>) -> String? {
        do {
            try store.setPinned(isPinned, ids: ids)
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setMenuRecentGroupLimit(_ recent: Int) {
        let nextRecent = max(0, recent)
        guard nextRecent != recentGroupLimit else {
            return
        }
        recentGroupLimit = nextRecent
        let usage = usageByBookmarkId
        recomputeMenuSpotlight(from: visibleBookmarks(from: bookmarks, usage: usage), usage: usage)
        onChange?()
    }

    @discardableResult
    func delete(id: UUID) -> String? {
        delete(ids: [id])
    }

    @discardableResult
    func delete(ids: Set<UUID>) -> String? {
        do {
            try store.delete(ids: ids)
            reload()
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    func recordUsage(for bookmark: Bookmark) {
        do {
            let date = Date()
            try store.database.recordUsage(bookmarkID: bookmark.id, at: date)
            let previous = usageByBookmarkId[bookmark.id]
            usageByBookmarkId[bookmark.id] = UsageRecord(
                count: (previous?.count ?? 0) + 1,
                lastClickedAt: date
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let visible = visibleBookmarks(from: bookmarks, usage: usageByBookmarkId)
        visibleBookmarksSnapshot = visible
        pinned = BookmarkListSortMode.storedForPinned.sorted(visible.filter(\.isPinned), usage: usageByBookmarkId)
        recomputeMenuSpotlight(from: visible, usage: usageByBookmarkId)
        onChange?()
    }

    func sortedBookmarks(_ bookmarks: [Bookmark], sortMode: BookmarkListSortMode) -> [Bookmark] {
        sortMode.sorted(bookmarks, usage: usageByBookmarkId)
    }

    func visibleUngroupedSections(
        sortMode: BookmarkListSortMode,
        showsSortControl: Bool = false
    ) -> [BookmarkListSection] {
        let bookmarks = sortedVisibleBookmarks(
            collectionId: nil,
            sortMode: sortMode
        )
        guard !bookmarks.isEmpty else { return [] }
        return [
            BookmarkListSection(
                title: "未分组 (\(bookmarks.count))",
                bookmarks: bookmarks,
                sortMode: showsSortControl ? sortMode : nil,
                sortScope: showsSortControl ? .ungrouped : nil
            )
        ]
    }

    func pinnedSections(
        sortMode: BookmarkListSortMode,
        showsSortControl: Bool = false
    ) -> [BookmarkListSection] {
        let usage = usageByBookmarkId
        let bookmarks = sortMode.sorted(visibleBookmarksSnapshot.filter(\.isPinned), usage: usage)
        guard !bookmarks.isEmpty else { return [] }
        return [
            BookmarkListSection(
                title: "置顶 (\(bookmarks.count))",
                bookmarks: bookmarks,
                sortMode: showsSortControl ? sortMode : nil,
                sortScope: showsSortControl ? .pinned : nil
            )
        ]
    }

    func visibleCollectionSections(
        sortMode: BookmarkListSortMode,
        includeEmptyCollections: Bool = false,
        showsSortControlOnFirstSection: Bool = false
    ) -> [BookmarkListSection] {
        let visibleByCollection = Dictionary(grouping: visibleBookmarksSnapshot.filter { !$0.isPinned }) {
            membershipByBookmarkId[$0.id]
        }
        var sections: [BookmarkListSection] = []
        for collection in collections {
            let bookmarks = sortMode.sorted(visibleByCollection[collection.id] ?? [], usage: usageByBookmarkId)
            guard includeEmptyCollections || !bookmarks.isEmpty else { continue }
            sections.append(
                BookmarkListSection(
                    title: "\(collection.name) (\(bookmarks.count))",
                    bookmarks: bookmarks,
                    sortMode: showsSortControlOnFirstSection && sections.isEmpty ? sortMode : nil,
                    collectionId: collection.id
                )
            )
        }
        return sections
    }

    func bookmarkLibrarySections(
        for candidates: [Bookmark],
        pinnedSortMode: BookmarkListSortMode,
        collectionSortMode: BookmarkListSortMode,
        ungroupedSortMode: BookmarkListSortMode
    ) -> [BookmarkListSection] {
        let usage = usageByBookmarkId
        var sections: [BookmarkListSection] = []

        let pinnedBookmarks = pinnedSortMode.sorted(
            candidates.filter(\.isPinned),
            usage: usage
        )
        let pinnedIds = Set(pinnedBookmarks.map(\.id))
        if !pinnedBookmarks.isEmpty {
            sections.append(
                BookmarkListSection(
                    title: "置顶 (\(pinnedBookmarks.count))",
                    bookmarks: pinnedBookmarks
                )
            )
        }

        let unpinnedCandidates = candidates.filter { !pinnedIds.contains($0.id) }
        let candidatesByCollection = Dictionary(grouping: unpinnedCandidates) {
            membershipByBookmarkId[$0.id]
        }
        for collection in collections {
            let bookmarks = collectionSortMode.sorted(candidatesByCollection[collection.id] ?? [], usage: usage)
            guard !bookmarks.isEmpty else { continue }
            sections.append(
                BookmarkListSection(
                    title: "\(collection.name) (\(bookmarks.count))",
                    bookmarks: bookmarks,
                    collectionId: collection.id
                )
            )
        }

        let ungroupedBookmarks = ungroupedSortMode.sorted(
            candidatesByCollection[nil] ?? [],
            usage: usage
        )
        if !ungroupedBookmarks.isEmpty {
            sections.append(
                BookmarkListSection(
                    title: "未分组 (\(ungroupedBookmarks.count))",
                    bookmarks: ungroupedBookmarks
                )
            )
        }

        return sections
    }

    func searchBookmarks(matching query: String, inCollection collectionId: UUID? = nil) -> [Bookmark] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingIDs = searchIndex.matchingIDs(query: trimmedQuery)
        return bookmarks.filter { bookmark in
            guard !bookmark.isHidden else { return false }
            if let collectionId, membershipByBookmarkId[bookmark.id] != collectionId {
                return false
            }
            return matchingIDs.contains(bookmark.id)
        }
    }

    func menuSections(
        pinnedSortMode: BookmarkListSortMode = .storedForPinned,
        ungroupedSortMode: BookmarkListSortMode = .storedForUngrouped,
        collectionSortMode: BookmarkListSortMode = .storedForCollections
    ) -> BookmarkMenuSections {
        BookmarkMenuSections(
            pinned: pinnedSections(sortMode: pinnedSortMode),
            recent: recent,
            collections: visibleCollectionSections(sortMode: collectionSortMode),
            ungrouped: visibleUngroupedSections(sortMode: ungroupedSortMode)
        )
    }

    func menuRenderSections(
        pinnedSortMode: BookmarkListSortMode = .storedForPinned,
        ungroupedSortMode: BookmarkListSortMode = .storedForUngrouped,
        collectionSortMode: BookmarkListSortMode = .storedForCollections
    ) -> [BookmarkMenuRenderSection] {
        let sections = menuSections(
            pinnedSortMode: pinnedSortMode,
            ungroupedSortMode: ungroupedSortMode,
            collectionSortMode: collectionSortMode
        )
        return sections.renderSections(order: BookmarkMenuSectionOrder.order(collections: collections))
    }

    private func sortedVisibleBookmarks(
        collectionId: UUID?,
        sortMode: BookmarkListSortMode
    ) -> [Bookmark] {
        let usage = usageByBookmarkId
        let scoped = visibleBookmarksSnapshot.filter { bookmark in
            !bookmark.isPinned &&
            membershipByBookmarkId[bookmark.id] == collectionId
        }
        return sortMode.sorted(scoped, usage: usage)
    }

    func createCollection(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "分组名称不能为空"
        }
        if collections.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "已存在同名分组"
        }

        do {
            let nextOrder = (collections.map(\.sortOrder).max() ?? -1) + 1
            try store.database.saveCollection(
                BookmarkCollection(name: trimmed, sortOrder: nextOrder)
            )
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func renameCollection(id: UUID, name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "分组名称不能为空"
        }
        if collections.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "已存在同名分组"
        }

        guard collections.contains(where: { $0.id == id }) else {
            return "找不到这个分组"
        }

        do {
            guard var collection = collections.first(where: { $0.id == id }) else {
                return "找不到这个分组"
            }
            collection.name = trimmed
            try store.database.saveCollection(collection)
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func deleteCollection(id: UUID) -> String? {
        do {
            try store.database.deleteCollection(id: id)
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setBookmarkCollection(bookmarkId: UUID, collectionId: UUID?) -> String? {
        if let collectionId, !collections.contains(where: { $0.id == collectionId }) {
            return "找不到这个分组"
        }
        guard bookmarks.contains(where: { $0.id == bookmarkId }) else {
            return "找不到这个书签"
        }

        do {
            try store.database.setCollection(collectionId, for: [bookmarkId])
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setBookmarkCollection(bookmarkIds: Set<UUID>, collectionId: UUID?) -> String? {
        guard !bookmarkIds.isEmpty else { return nil }
        if let collectionId, !collections.contains(where: { $0.id == collectionId }) {
            return "找不到这个分组"
        }

        do {
            let validIDs = bookmarkIds.intersection(bookmarks.map(\.id))
            try store.database.setCollection(collectionId, for: validIDs)
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func autoGroupBookmarks(bookmarkIds: Set<UUID> = []) async -> BookmarkAutoGroupingOutcome {
        guard UserDefaults.standard.object(forKey: Self.aiFeaturesEnabledKey) as? Bool ?? true else {
            return Self.emptyAutoGroupingOutcome(message: "Intelligence 功能已关闭", status: .failed)
        }

        guard !isOptimizingBookmarks, !isAutoGroupingBookmarks else {
            return Self.emptyAutoGroupingOutcome(message: "书签优化正在进行中", status: .failed)
        }

        return await autoGroupBookmarksStep(bookmarkIds: bookmarkIds)
    }

    private func autoGroupBookmarksStep(bookmarkIds: Set<UUID>) async -> BookmarkAutoGroupingOutcome {
        let candidates = autoGroupingCandidates(scopedTo: bookmarkIds)
        guard !candidates.isEmpty else {
            return Self.emptyAutoGroupingOutcome(message: "没有需要自动分组的书签")
        }
        guard !collections.isEmpty else {
            return Self.emptyAutoGroupingOutcome(message: "还没有可用分组")
        }

        isAutoGroupingBookmarks = true
        defer { isAutoGroupingBookmarks = false }

        do {
            let suggestions = try await groupOptimizer.suggestGroups(
                for: candidates.map {
                    BookmarkGroupingCandidate(
                        id: $0.id,
                        title: $0.title,
                        url: $0.url
                    )
                },
                existingCollections: collections.map {
                    BookmarkGroupingExistingCollection(id: $0.id, name: $0.name)
                }
            )
            let currentCandidates = autoGroupingCandidates(scopedTo: Set(candidates.map(\.id)))
            guard !currentCandidates.isEmpty else {
                return Self.emptyAutoGroupingOutcome(message: "没有需要自动分组的书签")
            }
            let result = try applyAutoGroupingSuggestions(suggestions, to: currentCandidates)
            reload()
            return BookmarkAutoGroupingOutcome(
                message: Self.autoGroupingMessage(groupedCount: result.groupedCount),
                groupedCount: result.groupedCount,
                placements: result.placements,
                status: result.groupedCount > 0 ? .changed : .noChange
            )
        } catch {
            return Self.emptyAutoGroupingOutcome(message: error.localizedDescription, status: .failed)
        }
    }

    private func autoGroupingCandidates(scopedTo bookmarkIds: Set<UUID>) -> [Bookmark] {
        let scope = bookmarkIds.isEmpty ? nil : bookmarkIds
        let usage = usageByBookmarkId
        return visibleBookmarks(from: bookmarks, usage: usage)
            .filter { bookmark in
                if let scope, !scope.contains(bookmark.id) {
                    return false
                }
                return !bookmark.isPinned && membershipByBookmarkId[bookmark.id] == nil
            }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    private func applyAutoGroupingSuggestions(
        _ suggestions: [UUID: String],
        to candidates: [Bookmark]
    ) throws -> (groupedCount: Int, placements: [AutoGroupedBookmarkPlacement]) {
        guard !suggestions.isEmpty else {
            return (0, [])
        }

        var groupedCount = 0
        var placements: [AutoGroupedBookmarkPlacement] = []

        let collectionIdByName = Dictionary(
            uniqueKeysWithValues: collections.map {
                (Self.normalizedCollectionName($0.name), $0.id)
            }
        )
        let collectionNameById = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0.name) })

        for bookmark in candidates {
            guard
                let rawGroupName = suggestions[bookmark.id],
                let groupName = Self.cleanedAutoGroupName(rawGroupName),
                let collectionId = collectionIdByName[Self.normalizedCollectionName(groupName)],
                membershipByBookmarkId[bookmark.id] != collectionId
            else {
                continue
            }
            try store.database.setCollection(collectionId, for: [bookmark.id])
            groupedCount += 1
            placements.append(
                AutoGroupedBookmarkPlacement(
                    bookmarkId: bookmark.id,
                    groupName: collectionNameById[collectionId] ?? groupName
                )
            )
        }

        return (groupedCount, placements)
    }

    private static func cleanedAutoGroupName(_ rawName: String) -> String? {
        let trimmed = rawName
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        guard !trimmed.isEmpty else { return nil }

        let normalized = normalizedCollectionName(trimmed)
        guard !["未分组", "ungrouped", "none", "null", "misc", "other"].contains(normalized) else {
            return nil
        }

        let maxLength = 24
        if trimmed.count > maxLength {
            return String(trimmed.prefix(maxLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func normalizedCollectionName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func autoGroupingMessage(groupedCount: Int) -> String {
        guard groupedCount > 0 else {
            return "没有书签被移动"
        }
        return "已自动分组 \(groupedCount) 个书签"
    }

    private static func emptyAutoGroupingOutcome(
        message: String,
        status: BookmarkAutoGroupingOutcome.Status = .noChange
    ) -> BookmarkAutoGroupingOutcome {
        BookmarkAutoGroupingOutcome(
            message: message,
            groupedCount: 0,
            placements: [],
            status: status
        )
    }

    func optimizeTitles(bookmarkIds: Set<UUID>) async -> String {
        await optimizeTitleDetails(bookmarkIds: bookmarkIds).message
    }

    func optimizeTitleDetails(bookmarkIds: Set<UUID>) async -> TitleOptimizationOutcome {
        guard UserDefaults.standard.object(forKey: Self.aiFeaturesEnabledKey) as? Bool ?? true else {
            return TitleOptimizationOutcome(
                message: "Intelligence 功能已关闭",
                optimizedTitles: [],
                status: .failed
            )
        }

        guard !isOptimizingBookmarks, !isOptimizingTitles else {
            return TitleOptimizationOutcome(
                message: "书签优化正在进行中",
                optimizedTitles: [],
                status: .failed
            )
        }

        return await optimizeTitleDetailsStep(bookmarkIds: bookmarkIds)
    }

    private func optimizeTitleDetailsStep(bookmarkIds: Set<UUID>) async -> TitleOptimizationOutcome {
        let candidates = bookmarks
            .filter { bookmark in
                bookmarkIds.contains(bookmark.id) && !bookmark.titleOptimized
                    && TitleOptimizationPreferences.allowsOptimization(for: bookmark)
            }
            .map {
                TitleOptimizationCandidate(
                    id: $0.id,
                    title: $0.title,
                    url: $0.url
                )
            }

        guard !candidates.isEmpty else {
            return TitleOptimizationOutcome(message: "没有需要优化的标题", optimizedTitles: [])
        }

        isOptimizingTitles = true
        defer { isOptimizingTitles = false }

        do {
            let candidateIds = Set(candidates.map(\.id))
            let optimizedTitles = try await titleOptimizer.optimize(candidates)
                .filter { candidateIds.contains($0.key) }
            let count = try store.applyTitleOptimizations(optimizedTitles)
            reload()
            if count == 0 {
                return TitleOptimizationOutcome(message: "没有标题被更新", optimizedTitles: [])
            }
            return TitleOptimizationOutcome(
                message: "已优化 \(count) 个标题",
                optimizedTitles: optimizedDisplayTitles(for: candidates, optimizedTitles: optimizedTitles),
                status: .changed
            )
        } catch {
            return TitleOptimizationOutcome(
                message: error.localizedDescription,
                optimizedTitles: [],
                status: .failed
            )
        }
    }

    func optimizeBookmarks(
        bookmarkIds: Set<UUID> = [],
        options: BookmarkIntelligenceOptimizationOptions
    ) async -> BookmarkIntelligenceOptimizationOutcome {
        guard UserDefaults.standard.object(forKey: Self.aiFeaturesEnabledKey) as? Bool ?? true else {
            let failure = "Intelligence 功能已关闭"
            return BookmarkIntelligenceOptimizationOutcome(
                titleOptimization: options.optimizeTitles
                    ? TitleOptimizationOutcome(message: failure, optimizedTitles: [], status: .failed)
                    : nil,
                autoGrouping: options.autoGroup
                    ? Self.emptyAutoGroupingOutcome(message: failure, status: .failed)
                    : nil
            )
        }

        guard !isOptimizingBookmarks, !isOptimizingTitles, !isAutoGroupingBookmarks else {
            let failure = "书签优化正在进行中"
            return BookmarkIntelligenceOptimizationOutcome(
                titleOptimization: options.optimizeTitles
                    ? TitleOptimizationOutcome(message: failure, optimizedTitles: [], status: .failed)
                    : nil,
                autoGrouping: options.autoGroup
                    ? Self.emptyAutoGroupingOutcome(message: failure, status: .failed)
                    : nil
            )
        }

        isOptimizingBookmarks = true
        defer { isOptimizingBookmarks = false }

        let scopedBookmarkIds = bookmarkIds.isEmpty
            ? Set(bookmarks.map(\.id))
            : bookmarkIds
        let titleOutcome = options.optimizeTitles
            ? await optimizeTitleDetailsStep(bookmarkIds: scopedBookmarkIds)
            : nil
        let groupingOutcome = options.autoGroup
            ? await autoGroupBookmarksStep(bookmarkIds: bookmarkIds)
            : nil

        return BookmarkIntelligenceOptimizationOutcome(
            titleOptimization: titleOutcome,
            autoGrouping: groupingOutcome
        )
    }

    private func optimizedDisplayTitles(
        for candidates: [TitleOptimizationCandidate],
        optimizedTitles: [UUID: String]
    ) -> [String] {
        let bookmarksById = Dictionary(uniqueKeysWithValues: bookmarks.map { ($0.id, $0) })
        return candidates.compactMap { candidate in
            guard
                let proposedTitle = optimizedTitles[candidate.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !proposedTitle.isEmpty,
                let bookmark = bookmarksById[candidate.id],
                bookmark.titleOptimized
            else {
                return nil
            }
            return bookmark.title
        }
    }

    func revertTitleOptimizations(bookmarkIds: Set<UUID>) -> String? {
        guard !bookmarkIds.isEmpty else { return nil }

        let revertableIds = bookmarkIds.filter { id in
            guard let bookmark = bookmarks.first(where: { $0.id == id }) else { return false }
            guard bookmark.titleOptimized else { return false }
            guard let original = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !original.isEmpty
            else {
                return false
            }
            return true
        }

        guard !revertableIds.isEmpty else {
            return "所选书签无法恢复原标题（需已 Intelligence 优化且保存了原标题）"
        }

        do {
            let count = try store.revertTitleOptimizations(ids: revertableIds)
            reload()
            if count == 0 {
                return "无法恢复原标题"
            }
            if count < bookmarkIds.count {
                return "已恢复 \(count) 个标题，\(bookmarkIds.count - count) 个跳过"
            }
            if bookmarkIds.count > 1 {
                return "已恢复 \(count) 个标题"
            }
            return "已恢复原标题"
        } catch {
            return error.localizedDescription
        }
    }

    /// Records a real "navigation" use of a bookmark — only menubar clicks
    /// should call this. The manage window's "open" action is a preview /
    /// integrity check, not usage, and must bypass this method to avoid
    /// polluting frecency.
    func openBookmark(_ bookmark: Bookmark) {
        guard let url = URL(string: bookmark.url) else { return }
        if bookmark.archivedAt != nil {
            try? store.setArchived(false, ids: [bookmark.id])
        }
        try? store.database.recordUsage(bookmarkID: bookmark.id, at: Date())
        reload()
        NSWorkspace.shared.open(url)
    }

    func openArchivedBookmark(_ bookmark: Bookmark) {
        openBookmark(bookmark)
    }

    private static func prunedMembership(
        _ membership: [UUID: UUID],
        collections: [BookmarkCollection],
        bookmarkIds: Set<UUID>
    ) -> [UUID: UUID] {
        let validCollectionIds = Set(collections.map(\.id))
        var pruned: [UUID: UUID] = [:]
        for (bookmarkId, collectionId) in membership {
            guard bookmarkIds.contains(bookmarkId), validCollectionIds.contains(collectionId) else {
                continue
            }
            pruned[bookmarkId] = collectionId
        }
        return pruned
    }

    private func recomputeMenuSpotlight(from all: [Bookmark], usage: [UUID: UsageRecord]) {
        let spotlightCandidates = all.filter { !$0.isPinned }
        let topRecent = BookmarkUsageRanking.recent(among: spotlightCandidates, limit: recentGroupLimit)
        let surfacedIds = Set(topRecent.map(\.id))

        recent = topRecent
        others = spotlightCandidates.filter { !surfacedIds.contains($0.id) }
    }

    func isEffectivelyArchived(_ bookmark: Bookmark) -> Bool {
        isEffectivelyArchived(bookmark, in: bookmarks, usage: usageByBookmarkId)
    }

    private struct AutoArchiveContext {
        var protectedIds: Set<Bookmark.ID>
        var cutoff: TimeInterval
        var now: Date
    }

    private func visibleBookmarks(from all: [Bookmark], usage: [UUID: UsageRecord], now: Date = Date()) -> [Bookmark] {
        let context = autoArchiveContext(in: all, usage: usage, now: now)
        return all.filter { !$0.isHidden && !isEffectivelyArchived($0, context: context, usage: usage) }
    }

    private func autoArchiveContext(in all: [Bookmark], usage: [UUID: UsageRecord], now: Date = Date()) -> AutoArchiveContext? {
        guard autoArchiveEnabled else {
            return nil
        }

        let active = all.filter { !$0.isHidden && $0.archivedAt == nil }
        let topFrequent = BookmarkUsageRanking.topFrequent(
            among: active,
            usage: usage,
            limit: Self.autoArchiveFrequentProtectionLimit,
            now: now
        )
        let frequentIds = Set(topFrequent.map(\.id))
        let recentCandidates = active.filter { !frequentIds.contains($0.id) }
        let topRecent = BookmarkUsageRanking.recent(among: recentCandidates, limit: recentGroupLimit)
        let groupedIds = Set(
            active.compactMap { bookmark -> UUID? in
                membershipByBookmarkId[bookmark.id]
            }
        )
        let pinnedIds = Set(active.filter(\.isPinned).map(\.id))
        let protectedIds = frequentIds.union(topRecent.map(\.id)).union(groupedIds).union(pinnedIds)
        let cutoff = TimeInterval(archiveAfterDays) * 86_400

        return AutoArchiveContext(protectedIds: protectedIds, cutoff: cutoff, now: now)
    }

    private func lastActiveDate(for bookmark: Bookmark, usage: [UUID: UsageRecord]) -> Date {
        let createdAt = bookmark.createdAt == .distantPast ? .distantPast : bookmark.createdAt
        guard let lastClickedAt = usage[bookmark.id]?.lastClickedAt else {
            return createdAt
        }
        return max(createdAt, lastClickedAt)
    }

    private func isEffectivelyArchived(
        _ bookmark: Bookmark,
        in all: [Bookmark],
        usage: [UUID: UsageRecord],
        now: Date = Date()
    ) -> Bool {
        isEffectivelyArchived(
            bookmark,
            context: autoArchiveContext(in: all, usage: usage, now: now),
            usage: usage
        )
    }

    private func isEffectivelyArchived(
        _ bookmark: Bookmark,
        context: AutoArchiveContext?,
        usage: [UUID: UsageRecord]
    ) -> Bool {
        guard !bookmark.isHidden else {
            return false
        }
        if bookmark.archivedAt != nil {
            return true
        }
        guard autoArchiveEnabled else {
            return false
        }
        guard let context, !context.protectedIds.contains(bookmark.id)
        else {
            return false
        }

        return context.now.timeIntervalSince(lastActiveDate(for: bookmark, usage: usage)) >= context.cutoff
    }
}
