import AppKit
import Foundation
import Observation
import ObeliskCore

@MainActor
@Observable
final class BookmarksModel {
    static let autoArchiveEnabledKey = "autoArchiveIdleBookmarks"
    static let archiveAfterDaysKey = "archiveAfterDays"
    static let aiFeaturesEnabledKey = "aiFeaturesEnabled"
    static let developerFeaturesEnabledKey = "developerFeaturesEnabled"
    static let defaultDebugSidebarIconTileSize: Double = 22
    static let defaultDebugSidebarIconSymbolSize: Double = 11
    static let defaultDebugSidebarIconCornerRadius: Double = 6
    static let minArchiveAfterDays = 3
    static let maxArchiveAfterDays = 30
    static let defaultArchiveAfterDays = 30

    private(set) var bookmarks: [Bookmark] = []
    /// Top-N most frecent bookmarks (≥3 clicks, decayed).
    private(set) var frequent: [Bookmark] = []
    /// Top-N by createdAt, excluding any already in `frequent`.
    private(set) var recent: [Bookmark] = []
    /// User-pinned visible bookmarks. These are excluded from the smart
    /// spotlight and library sections so they only appear in the pinned group.
    private(set) var pinned: [Bookmark] = []
    /// Remaining bookmarks not surfaced in the two groups above. Each
    /// bookmark appears in exactly one of `frequent` / `recent` / `others`,
    /// so a single List with selection can show all three sections without
    /// duplicate IDs.
    /// Bookmarks not shown in menu spotlight (frequent/recent).
    private(set) var others: [Bookmark] = []
    /// User-defined collections, sorted by `sortOrder` then name.
    private(set) var collections: [BookmarkCollection] = []
    private var membershipByBookmarkId: [UUID: UUID] = [:]
    var errorMessage: String?
    private(set) var loadErrorMessage: String?

    /// Fired whenever the model's published state changes (reload or open).
    /// AppDelegate uses this to drive menubar rebuilds so menubar and the
    /// manage window stay in sync without recomputing groups twice.
    @ObservationIgnored var onChange: (() -> Void)?

    private let store: BookmarkStore
    private let usageStore: UsageStore
    private let groupStore: BookmarkGroupStore
    private let titleOptimizer: TitleOptimizer
    private var frequentGroupLimit: Int
    private var recentGroupLimit: Int
    private(set) var isOptimizingTitles = false

    var rootDirectory: URL {
        store.rootDirectory
    }

    func invalidateStorageCaches() {
        store.invalidateCache()
        usageStore.invalidateCache()
        groupStore.invalidateCache()
    }

    func updateStorageRootDirectory(_ rootDirectory: URL) {
        groupStore.updateRootDirectory(rootDirectory)
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
        usageStore: UsageStore,
        frequentGroupLimit: Int = 5,
        recentGroupLimit: Int = 5
    ) {
        self.store = store
        self.usageStore = usageStore
        self.groupStore = BookmarkGroupStore(rootDirectory: store.rootDirectory)
        self.titleOptimizer = TitleOptimizer(rootDirectory: store.rootDirectory)
        self.frequentGroupLimit = frequentGroupLimit
        self.recentGroupLimit = recentGroupLimit
        reload()
    }

    func reload() {
        do {
            let all = try store.bookmarks()
            // Prune usage entries for deleted bookmarks. Cheap; only writes
            // when there are actually orphans.
            usageStore.cleanup(validIds: Set(all.map(\.id)))
            let usage = usageStore.load()
            bookmarks = all
            let groupData = groupStore.load()
            collections = groupData.collections.sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            membershipByBookmarkId = Self.prunedMembership(
                groupData.membershipByBookmarkId,
                collections: collections,
                bookmarkIds: Set(all.map(\.id))
            )
            let visibleBookmarks = visibleBookmarks(from: all, usage: usage)
            pinned = BookmarkListSortMode.stored.sorted(visibleBookmarks.filter(\.isPinned))
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
        let priorFrequent = frequent.map(\.id)
        let priorRecent = recent.map(\.id)
        let priorOthers = others.map(\.id)
        let priorPinned = pinned.map(\.id)

        let usage = usageStore.load()
        let visibleBookmarks = visibleBookmarks(from: bookmarks, usage: usage)
        pinned = BookmarkListSortMode.stored.sorted(visibleBookmarks.filter(\.isPinned))
        recomputeMenuSpotlight(from: visibleBookmarks, usage: usage)

        let changed = frequent.map(\.id) != priorFrequent
            || recent.map(\.id) != priorRecent
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
            let bookmark = try store.add(title: title, url: url, isHidden: isHidden)
            reload()
            return .success(bookmark)
        } catch {
            return .failure(error)
        }
    }

    func update(_ bookmark: Bookmark) -> String? {
        do {
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

    func setMenuGroupLimits(frequent: Int, recent: Int) {
        let nextFrequent = max(0, frequent)
        let nextRecent = max(0, recent)
        guard nextFrequent != frequentGroupLimit || nextRecent != recentGroupLimit else {
            return
        }
        frequentGroupLimit = nextFrequent
        recentGroupLimit = nextRecent
        let usage = usageStore.load()
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
            try groupStore.removeMembership(for: ids)
            reload()
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    func visibleUngroupedSections(
        searchText: String = "",
        sortMode: BookmarkListSortMode,
        showsSortControl: Bool = false
    ) -> [BookmarkListSection] {
        let bookmarks = sortedVisibleBookmarks(
            collectionId: nil,
            searchText: searchText,
            sortMode: sortMode
        )
        guard !bookmarks.isEmpty else { return [] }
        return [
            BookmarkListSection(
                title: "未分组 (\(bookmarks.count))",
                bookmarks: bookmarks,
                sortMode: showsSortControl ? sortMode : nil
            )
        ]
    }

    func pinnedSections(
        searchText: String = "",
        sortMode: BookmarkListSortMode,
        showsSortControl: Bool = false
    ) -> [BookmarkListSection] {
        let usage = usageStore.load()
        let bookmarks = sortMode.sorted(
            filteredBookmarks(
                visibleBookmarks(from: self.bookmarks, usage: usage).filter(\.isPinned),
                searchText: searchText
            )
        )
        guard !bookmarks.isEmpty else { return [] }
        return [
            BookmarkListSection(
                title: "置顶 (\(bookmarks.count))",
                bookmarks: bookmarks,
                sortMode: showsSortControl ? sortMode : nil
            )
        ]
    }

    func visibleCollectionSections(
        searchText: String = "",
        sortMode: BookmarkListSortMode,
        includeEmptyCollections: Bool = false,
        showsSortControlOnFirstSection: Bool = false
    ) -> [BookmarkListSection] {
        var sections: [BookmarkListSection] = []
        for collection in collections {
            let bookmarks = sortedVisibleBookmarks(
                collectionId: collection.id,
                searchText: searchText,
                sortMode: sortMode
            )
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

    func menuLibrarySections(sortMode: BookmarkListSortMode = .stored) -> [BookmarkListSection] {
        visibleCollectionSections(sortMode: sortMode)
            + visibleUngroupedSections(sortMode: sortMode)
    }

    func menuPinnedSections(sortMode: BookmarkListSortMode = .stored) -> [BookmarkListSection] {
        pinnedSections(sortMode: sortMode)
    }

    private func sortedVisibleBookmarks(
        collectionId: UUID?,
        searchText: String = "",
        sortMode: BookmarkListSortMode
    ) -> [Bookmark] {
        let usage = usageStore.load()
        let visible = visibleBookmarks(from: bookmarks, usage: usage)
        let filtered = filteredBookmarks(
            visible.filter { bookmark in
                !bookmark.isPinned &&
                membershipByBookmarkId[bookmark.id] == collectionId
            },
            searchText: searchText
        )
        return sortMode.sorted(filtered)
    }

    private func filteredBookmarks(_ bookmarks: [Bookmark], searchText: String) -> [Bookmark] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return bookmarks }
        return bookmarks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.url.localizedCaseInsensitiveContains(query)
        }
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
            try groupStore.update { database in
                let nextOrder = (database.collections.map(\.sortOrder).max() ?? -1) + 1
                database.collections.append(
                    BookmarkCollection(name: trimmed, sortOrder: nextOrder)
                )
            }
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
            try groupStore.update { database in
                guard let index = database.collections.firstIndex(where: { $0.id == id }) else { return }
                database.collections[index].name = trimmed
            }
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func deleteCollection(id: UUID) -> String? {
        do {
            try groupStore.update { database in
                database.collections.removeAll { $0.id == id }
                database.membershipByBookmarkId = database.membershipByBookmarkId.filter { $0.value != id }
            }
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
            try groupStore.update { database in
                if let collectionId {
                    database.membershipByBookmarkId[bookmarkId] = collectionId
                } else {
                    database.membershipByBookmarkId.removeValue(forKey: bookmarkId)
                }
            }
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
            try groupStore.update { database in
                for bookmarkId in bookmarkIds {
                    guard bookmarks.contains(where: { $0.id == bookmarkId }) else { continue }
                    if let collectionId {
                        database.membershipByBookmarkId[bookmarkId] = collectionId
                    } else {
                        database.membershipByBookmarkId.removeValue(forKey: bookmarkId)
                    }
                }
            }
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func optimizeTitles(bookmarkIds: Set<UUID>) async -> String {
        guard UserDefaults.standard.object(forKey: Self.aiFeaturesEnabledKey) as? Bool ?? true else {
            return "Intelligence 功能已关闭"
        }

        guard !isOptimizingTitles else {
            return "标题优化正在进行中"
        }

        let candidates = bookmarks
            .filter { bookmark in
                bookmarkIds.contains(bookmark.id) && !bookmark.titleOptimized
            }
            .map {
                TitleOptimizationCandidate(
                    id: $0.id,
                    title: $0.title,
                    url: $0.url
                )
            }

        guard !candidates.isEmpty else {
            return "没有需要优化的标题"
        }

        isOptimizingTitles = true
        defer { isOptimizingTitles = false }

        do {
            let optimizedTitles = try await titleOptimizer.optimize(candidates)
            let count = try store.applyTitleOptimizations(optimizedTitles)
            reload()
            if count == 0 {
                return "没有标题被更新"
            }
            return "已优化 \(count) 个标题"
        } catch {
            return error.localizedDescription
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

    func restoreAllOriginalTitles() -> String {
        guard UserDefaults.standard.bool(forKey: Self.developerFeaturesEnabledKey) else {
            return "开发者选项已关闭"
        }

        do {
            let count = try store.restoreAllOriginalTitles()
            reload()
            if count == 0 {
                return "没有可恢复的原标题"
            }
            return "已恢复 \(count) 个标题"
        } catch {
            return error.localizedDescription
        }
    }

    func fetchAllOriginalTitles() async -> String {
        guard UserDefaults.standard.bool(forKey: Self.developerFeaturesEnabledKey) else {
            return "开发者选项已关闭"
        }

        guard !isOptimizingTitles else {
            return "标题优化正在进行中"
        }

        isOptimizingTitles = true
        defer { isOptimizingTitles = false }

        let fetcher = PageMetadataFetcher()
        var titles: [UUID: String] = [:]
        var failedCount = 0

        for bookmark in bookmarks {
            guard let url = URL(string: bookmark.url) else {
                failedCount += 1
                continue
            }
            if let title = await fetcher.title(for: url) {
                titles[bookmark.id] = title
            } else {
                failedCount += 1
            }
        }

        guard !titles.isEmpty else {
            return failedCount > 0 ? "未能获取任何原标题" : "没有书签可处理"
        }

        do {
            let count = try store.applyOriginalTitles(titles, forceApplyDisplay: true)
            reload()
            if failedCount > 0 {
                return "已应用 \(count) 个标题，\(failedCount) 个失败"
            }
            return "已应用 \(count) 个标题"
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
        usageStore.record(id: bookmark.id)
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
        let topFrequent = usageStore.topFrequent(among: spotlightCandidates, usage: usage, limit: frequentGroupLimit)
        let frequentIds = Set(topFrequent.map(\.id))

        // Recent excludes anything already shown in "frequent" so each
        // bookmark only appears once.
        let recentCandidates = spotlightCandidates.filter { !frequentIds.contains($0.id) }
        let topRecent = usageStore.recent(among: recentCandidates, limit: recentGroupLimit)

        let surfacedIds = frequentIds.union(topRecent.map(\.id))

        frequent = topFrequent
        recent = topRecent
        others = spotlightCandidates.filter { !surfacedIds.contains($0.id) }
    }

    func isEffectivelyArchived(_ bookmark: Bookmark) -> Bool {
        let usage = usageStore.load()
        return isEffectivelyArchived(bookmark, in: bookmarks, usage: usage)
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
        let topFrequent = usageStore.topFrequent(among: active, usage: usage, limit: frequentGroupLimit, now: now)
        let frequentIds = Set(topFrequent.map(\.id))
        let recentCandidates = active.filter { !frequentIds.contains($0.id) }
        let topRecent = usageStore.recent(among: recentCandidates, limit: recentGroupLimit)
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
        guard autoArchiveEnabled else {
            return false
        }
        guard !bookmark.isHidden else {
            return false
        }
        if bookmark.archivedAt != nil {
            return true
        }
        guard let context, !context.protectedIds.contains(bookmark.id)
        else {
            return false
        }

        return context.now.timeIntervalSince(lastActiveDate(for: bookmark, usage: usage)) >= context.cutoff
    }
}
