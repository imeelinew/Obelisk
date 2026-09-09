import AppKit
import Foundation
import ObeliskCore
import ObeliskData
import Observation

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
    private let intelligence: BookmarkIntelligence
    private var recentGroupLimit: Int
    var isOptimizingTitles: Bool { intelligence.isOptimizingTitles }
    var isAutoGroupingBookmarks: Bool { intelligence.isAutoGroupingBookmarks }
    var isOptimizingBookmarks: Bool { intelligence.isOptimizingBookmarks }

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
        self.intelligence = BookmarkIntelligence(
            titleOptimizer: titleOptimizer,
            groupOptimizer: groupOptimizer
        )
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
        setHidden(isHidden, for: [id])
    }

    func setHidden(_ isHidden: Bool, for ids: Set<UUID>) -> String? {
        guard !ids.isEmpty else { return nil }
        var lastError: String?
        for id in ids {
            guard var bookmark = bookmarks.first(where: { $0.id == id }) else {
                lastError = "找不到这个书签"
                continue
            }
            guard bookmark.isHidden != isHidden else { continue }
            if !isHidden, HiddenBookmarkKeywordExclusion.matches(url: bookmark.url) {
                lastError = HiddenBookmarkKeywordExclusion.blockedBookmarkMessage
                continue
            }
            bookmark.isHidden = isHidden
            if let error = update(bookmark) {
                lastError = error
            }
        }
        return lastError
    }

    func setArchived(_ isArchived: Bool, for id: UUID) -> String? {
        setArchived(isArchived, for: [id])
    }

    func setArchived(_ isArchived: Bool, for ids: Set<UUID>) -> String? {
        guard !ids.isEmpty else { return nil }
        do {
            try store.setArchived(isArchived, ids: ids)
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
                title: "\("未分组".obeliskLocalized) (\(bookmarks.count))",
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
                title: "\("置顶".obeliskLocalized) (\(bookmarks.count))",
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
                    title: "\("置顶".obeliskLocalized) (\(pinnedBookmarks.count))",
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
                    title: "\("未分组".obeliskLocalized) (\(ungroupedBookmarks.count))",
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
        do {
            try store.createCollection(name: name)
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func renameCollection(id: UUID, name: String) -> String? {
        do {
            try store.renameCollection(id: id, name: name)
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func deleteCollection(id: UUID) -> String? {
        do {
            try store.deleteCollection(id: id)
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setBookmarkCollection(bookmarkId: UUID, collectionId: UUID?) -> String? {
        do {
            try store.setCollection(collectionId, for: [bookmarkId])
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setBookmarkCollection(bookmarkIds: Set<UUID>, collectionId: UUID?) -> String? {
        guard !bookmarkIds.isEmpty else { return nil }
        do {
            let validIDs = bookmarkIds.intersection(bookmarks.map(\.id))
            try store.setCollection(collectionId, for: validIDs)
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func autoGroupingCandidates(scopedTo bookmarkIds: Set<UUID>) -> [Bookmark] {
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

    func applyAutoGroupingSuggestions(
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
            try store.setCollection(collectionId, for: [bookmark.id])
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

    func autoGroupBookmarks(bookmarkIds: Set<UUID> = []) async -> BookmarkAutoGroupingOutcome {
        await intelligence.autoGroupBookmarks(in: self, bookmarkIds: bookmarkIds)
    }

    func optimizeTitleDetails(bookmarkIds: Set<UUID>) async -> TitleOptimizationOutcome {
        await intelligence.optimizeTitleDetails(in: self, bookmarkIds: bookmarkIds)
    }

    func optimizeBookmarks(
        bookmarkIds: Set<UUID> = [],
        options: BookmarkIntelligenceOptimizationOptions
    ) async -> BookmarkIntelligenceOptimizationOutcome {
        await intelligence.optimizeBookmarks(in: self, bookmarkIds: bookmarkIds, options: options)
    }

    /// Intelligence commits through the same local store as manual edits.
    func applyTitleOptimizations(_ titles: [UUID: String]) throws -> Int {
        try store.applyTitleOptimizations(titles)
    }

    func optimizeTitles(bookmarkIds: Set<UUID>) async -> String {
        await optimizeTitleDetails(bookmarkIds: bookmarkIds).message
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
                membershipByBookmarkId[bookmark.id] == nil ? nil : bookmark.id
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
