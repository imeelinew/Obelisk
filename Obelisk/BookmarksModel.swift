import AppKit
import Foundation
import ObeliskCore
import ObeliskData
import Observation

private struct BookmarkValidationError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

struct CollectionAssignmentFeedback: Equatable {
    enum Target: Hashable {
        case collection(UUID)
        case ungrouped
    }

    let token: UUID
    let destination: Target
    let sources: Set<Target>

    var animatedTargets: Set<Target> {
        sources.union([destination])
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
    private(set) var recent: [Bookmark] = []
    private(set) var collections: [BookmarkCollection] = []
    private(set) var visibleBookmarksSnapshot: [Bookmark] = []
    private(set) var hiddenBookmarksSnapshot: [Bookmark] = []
    private(set) var archivedBookmarksSnapshot: [Bookmark] = []
    private(set) var visibleBookmarksByCollectionID: [UUID: [Bookmark]] = [:]
    private(set) var visibleUngroupedBookmarks: [Bookmark] = []
    private var membershipByBookmarkID: [UUID: UUID] = [:]
    private var usageByBookmarkID: [UUID: UsageRecord] = [:]
    private var searchIndex = BookmarkSearchIndex(bookmarks: [])
    var errorMessage: String?
    private(set) var loadErrorMessage: String?
    private(set) var lastCollectionAssignmentFeedback: CollectionAssignmentFeedback?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var pendingAssignmentFeedback: CollectionAssignmentFeedback?

    private let store: BookmarkStore
    private let intelligence: BookmarkIntelligence
    private var recentGroupLimit: Int
    @ObservationIgnored private var titleOptimizationTail: Task<Void, Never>?

    var isOptimizingTitles: Bool { intelligence.isOptimizingTitles }
    var rootDirectory: URL { store.rootDirectory }

    init(
        store: BookmarkStore,
        recentGroupLimit: Int = 5,
        titleOptimizer: (any TitleOptimizing)? = nil
    ) {
        self.store = store
        self.intelligence = BookmarkIntelligence(titleOptimizer: titleOptimizer)
        self.recentGroupLimit = recentGroupLimit
        reload()
    }

    func collectionId(for bookmarkId: UUID) -> UUID? {
        membershipByBookmarkID[bookmarkId]
    }

    private func visibleCollectionAssignmentTarget(for bookmarkID: UUID) -> CollectionAssignmentFeedback.Target? {
        guard let bookmark = bookmarks.first(where: { $0.id == bookmarkID }),
              !bookmark.isHidden,
              !isEffectivelyArchived(bookmark) else {
            return nil
        }
        if let collectionID = membershipByBookmarkID[bookmarkID] {
            return .collection(collectionID)
        }
        return .ungrouped
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

    func reload() {
        do {
            let snapshot = try store.snapshot()
            let all = snapshot.bookmarks
            bookmarks = all
            usageByBookmarkID = snapshot.usageByBookmarkID
            searchIndex = BookmarkSearchIndex(bookmarks: all)
            collections = snapshot.collections.sorted(by: Self.collectionOrder)
            membershipByBookmarkID = Self.prunedMembership(
                snapshot.collectionByBookmarkID,
                collections: collections,
                bookmarkIDs: Set(all.map(\.id))
            )
            recomputePreparedContent()
            let priorLoadError = loadErrorMessage
            loadErrorMessage = nil
            if errorMessage == priorLoadError {
                errorMessage = nil
            }
            if let pending = pendingAssignmentFeedback {
                pendingAssignmentFeedback = nil
                lastCollectionAssignmentFeedback = pending
            }
            onChange?()
        } catch {
            pendingAssignmentFeedback = nil
            let message = error.localizedDescription
            loadErrorMessage = message
            errorMessage = message
            onChange?()
        }
    }

    @discardableResult
    func applyAutoArchiveIfNeeded() -> Bool {
        let previousVisibleIDs = visibleBookmarksSnapshot.map(\.id)
        let previousRecentIDs = recent.map(\.id)
        recomputePreparedContent()
        let changed = previousVisibleIDs != visibleBookmarksSnapshot.map(\.id)
            || previousRecentIDs != recent.map(\.id)
        if changed { onChange?() }
        return changed
    }

    func add(title: String, url: String, isHidden: Bool = false, collectionID: UUID? = nil) -> String? {
        switch addBookmark(title: title, url: url, isHidden: isHidden, collectionID: collectionID) {
        case .success: nil
        case .failure(let error): error.localizedDescription
        }
    }

    func addBookmark(
        title: String,
        url: String,
        isHidden: Bool = false,
        collectionID: UUID? = nil
    ) -> Result<Bookmark, Error> {
        do {
            guard isHidden || !HiddenBookmarkKeywordExclusion.matches(url: url) else {
                return .failure(BookmarkValidationError(message: HiddenBookmarkKeywordExclusion.blockedBookmarkMessage))
            }
            let bookmark = try store.add(
                title: title,
                url: url,
                isHidden: isHidden,
                collectionID: collectionID
            )
            if !isHidden {
                pendingAssignmentFeedback = CollectionAssignmentFeedback(
                    token: UUID(),
                    destination: collectionID.map { .collection($0) } ?? .ungrouped,
                    sources: []
                )
            }
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
            if let error = update(bookmark) { lastError = error }
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

    func setMenuRecentGroupLimit(_ recent: Int) {
        let nextRecent = max(0, recent)
        guard nextRecent != recentGroupLimit else { return }
        recentGroupLimit = nextRecent
        recomputePreparedContent()
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
            let previous = usageByBookmarkID[bookmark.id]
            usageByBookmarkID[bookmark.id] = UsageRecord(
                count: (previous?.count ?? 0) + 1,
                lastClickedAt: date
            )
            recomputePreparedContent()
            onChange?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func bookmarks(in collectionID: UUID) -> [Bookmark] {
        visibleBookmarksByCollectionID[collectionID] ?? []
    }

    func sortedBookmarks(_ bookmarks: [Bookmark], by mode: BookmarkListSortMode) -> [Bookmark] {
        switch mode {
        case .recentlyAdded:
            bookmarks.sorted(by: Self.bookmarkTimeOrder)
        case .recentlyUsed:
            BookmarkUsageRanking.recentlyUsedSorted(among: bookmarks, usage: usageByBookmarkID)
        case .mostFrequentlyUsed:
            BookmarkUsageRanking.mostFrequentlyUsedSorted(among: bookmarks, usage: usageByBookmarkID)
        }
    }

    func menuSections() -> BookmarkMenuSections {
        let sortMode = BookmarkListSortMode(
            rawValue: UserDefaults.standard.string(forKey: BookmarkListSortMode.storageKey) ?? ""
        ) ?? .recentlyAdded
        return BookmarkMenuSections(
            recent: sortedBookmarks(recent, by: sortMode),
            collections: collections.map { collection in
                BookmarkMenuSection(
                    id: .collection(collection.id),
                    title: collection.name,
                    bookmarks: sortedBookmarks(
                        visibleBookmarksByCollectionID[collection.id] ?? [],
                        by: sortMode
                    )
                )
            },
            ungrouped: sortedBookmarks(visibleUngroupedBookmarks, by: sortMode)
        )
    }

    func menuRenderSections() -> [BookmarkMenuRenderSection] {
        menuSections().renderSections(
            expandedIDs: BookmarkMenuExpansionPreferences.expandedIDs(collections: collections)
        )
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

    func reorderCollections(_ orderedIDs: [UUID]) -> String? {
        do {
            try store.reorderCollections(orderedIDs)
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setBookmarkCollection(bookmarkId: UUID, collectionId: UUID?) -> String? {
        setBookmarkCollection(bookmarkIds: [bookmarkId], collectionId: collectionId)
    }

    func setBookmarkCollection(bookmarkIds: Set<UUID>, collectionId: UUID?) -> String? {
        guard !bookmarkIds.isEmpty else { return nil }
        do {
            let validIDs = bookmarkIds.intersection(Set(bookmarks.map(\.id)))
            let destination: CollectionAssignmentFeedback.Target = collectionId.map { .collection($0) } ?? .ungrouped
            var sources: Set<CollectionAssignmentFeedback.Target> = []
            var didMoveVisible = false
            for id in validIDs {
                guard let current = visibleCollectionAssignmentTarget(for: id) else { continue }
                if current == destination { continue }
                didMoveVisible = true
                sources.insert(current)
            }
            try store.setCollection(collectionId, for: validIDs)
            if didMoveVisible {
                pendingAssignmentFeedback = CollectionAssignmentFeedback(
                    token: UUID(),
                    destination: destination,
                    sources: sources
                )
            }
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func searchBookmarks(matching query: String, inCollection collectionID: UUID? = nil) -> [Bookmark] {
        let matchingIDs = searchIndex.matchingIDs(
            query: query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return bookmarks.filter { bookmark in
            guard !bookmark.isHidden, !isEffectivelyArchived(bookmark) else { return false }
            if let collectionID, membershipByBookmarkID[bookmark.id] != collectionID { return false }
            return matchingIDs.contains(bookmark.id)
        }
        .sorted(by: Self.bookmarkTimeOrder)
    }

    func optimizeTitleDetails(bookmarkIds: Set<UUID>) async -> TitleOptimizationOutcome {
        await intelligence.optimizeTitleDetails(in: self, bookmarkIds: bookmarkIds)
    }

    func enqueueTitleOptimization(bookmarkIds: Set<UUID>) async -> TitleOptimizationOutcome {
        await withCheckedContinuation { continuation in
            let previous = titleOptimizationTail
            titleOptimizationTail = Task { [weak self] in
                _ = await previous?.result
                guard let self else {
                    continuation.resume(returning: TitleOptimizationOutcome(
                        message: "标题优化已取消",
                        optimizedTitles: [],
                        status: .failed
                    ))
                    return
                }
                let outcome = await self.optimizeTitleDetails(bookmarkIds: bookmarkIds)
                continuation.resume(returning: outcome)
            }
        }
    }

    func applyTitleOptimizations(_ titles: [UUID: String]) throws -> Int {
        try store.applyTitleOptimizations(titles)
    }

    func markTitleOptimizationFailed(_ ids: Set<UUID>) throws {
        _ = try store.markTitleOptimizationFailed(ids: ids)
    }

    func revertTitleOptimizations(bookmarkIds: Set<UUID>) -> String? {
        guard !bookmarkIds.isEmpty else { return nil }
        let revertableIDs = bookmarkIds.filter { id in
            guard let bookmark = bookmarks.first(where: { $0.id == id }) else { return false }
            guard bookmark.titleOptimizationState == .succeeded else { return false }
            let original = bookmark.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !original.isEmpty
        }
        guard !revertableIDs.isEmpty else {
            return "所选书签无法恢复原标题（需已 Intelligence 优化且保存了原标题）"
        }
        do {
            let count = try store.revertTitleOptimizations(ids: revertableIDs)
            reload()
            if count == 0 { return "无法恢复原标题" }
            if count < bookmarkIds.count {
                return "已恢复 \(count) 个标题，\(bookmarkIds.count - count) 个跳过"
            }
            return bookmarkIds.count > 1 ? "已恢复 \(count) 个标题" : "已恢复原标题"
        } catch {
            return error.localizedDescription
        }
    }

    func openBookmark(_ bookmark: Bookmark) {
        guard let url = URL(string: bookmark.url) else { return }
        guard NSWorkspace.shared.open(url) else { return }
        if bookmark.archivedAt != nil {
            try? store.setArchived(false, ids: [bookmark.id])
        }
        try? store.database.recordUsage(bookmarkID: bookmark.id, at: Date())
        reload()
    }

    func openArchivedBookmark(_ bookmark: Bookmark) {
        openBookmark(bookmark)
    }

    func isEffectivelyArchived(_ bookmark: Bookmark) -> Bool {
        isEffectivelyArchived(bookmark, in: bookmarks, usage: usageByBookmarkID)
    }

    private func recomputePreparedContent() {
        let context = autoArchiveContext(in: bookmarks, usage: usageByBookmarkID)
        let visible = bookmarks
            .filter { !$0.isHidden && !isEffectivelyArchived($0, context: context, usage: usageByBookmarkID) }
            .sorted(by: Self.bookmarkTimeOrder)
        visibleBookmarksSnapshot = visible
        hiddenBookmarksSnapshot = bookmarks
            .filter { $0.isHidden && !isEffectivelyArchived($0, context: context, usage: usageByBookmarkID) }
            .sorted(by: Self.bookmarkTimeOrder)
        archivedBookmarksSnapshot = bookmarks
            .filter { !$0.isHidden && isEffectivelyArchived($0, context: context, usage: usageByBookmarkID) }
            .sorted(by: Self.bookmarkTimeOrder)
        recent = Array(visible.prefix(recentGroupLimit))
        visibleBookmarksByCollectionID = Dictionary(grouping: visible.compactMap { bookmark -> Bookmark? in
            membershipByBookmarkID[bookmark.id] == nil ? nil : bookmark
        }) { bookmark in
            membershipByBookmarkID[bookmark.id]!
        }
        visibleUngroupedBookmarks = visible.filter { membershipByBookmarkID[$0.id] == nil }
    }

    private static func collectionOrder(_ lhs: BookmarkCollection, _ rhs: BookmarkCollection) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func bookmarkTimeOrder(_ lhs: Bookmark, _ rhs: Bookmark) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func prunedMembership(
        _ membership: [UUID: UUID],
        collections: [BookmarkCollection],
        bookmarkIDs: Set<UUID>
    ) -> [UUID: UUID] {
        let validCollectionIDs = Set(collections.map(\.id))
        return membership.filter {
            bookmarkIDs.contains($0.key) && validCollectionIDs.contains($0.value)
        }
    }

    private struct AutoArchiveContext {
        var protectedIDs: Set<Bookmark.ID>
        var cutoff: TimeInterval
        var now: Date
    }

    private func visibleBookmarks(
        from all: [Bookmark],
        usage: [UUID: UsageRecord],
        now: Date = Date()
    ) -> [Bookmark] {
        let context = autoArchiveContext(in: all, usage: usage, now: now)
        return all.filter { !$0.isHidden && !isEffectivelyArchived($0, context: context, usage: usage) }
    }

    private func autoArchiveContext(
        in all: [Bookmark],
        usage: [UUID: UsageRecord],
        now: Date = Date()
    ) -> AutoArchiveContext? {
        guard autoArchiveEnabled else { return nil }
        let active = all.filter { !$0.isHidden && $0.archivedAt == nil }
        let frequent = BookmarkUsageRanking.topFrequent(
            among: active,
            usage: usage,
            limit: Self.autoArchiveFrequentProtectionLimit,
            now: now
        )
        let frequentIDs = Set(frequent.map(\.id))
        let recentCandidates = active.filter { !frequentIDs.contains($0.id) }
        let recentIDs = Set(
            BookmarkUsageRanking.recent(among: recentCandidates, limit: recentGroupLimit).map(\.id)
        )
        let groupedIDs = Set(active.compactMap { membershipByBookmarkID[$0.id] == nil ? nil : $0.id })
        return AutoArchiveContext(
            protectedIDs: frequentIDs.union(recentIDs).union(groupedIDs),
            cutoff: TimeInterval(archiveAfterDays) * 86_400,
            now: now
        )
    }

    private func lastActiveDate(for bookmark: Bookmark, usage: [UUID: UsageRecord]) -> Date {
        guard let lastClickedAt = usage[bookmark.id]?.lastClickedAt else { return bookmark.createdAt }
        return max(bookmark.createdAt, lastClickedAt)
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
        guard !bookmark.isHidden else { return false }
        if bookmark.archivedAt != nil { return true }
        guard autoArchiveEnabled, let context, !context.protectedIDs.contains(bookmark.id) else {
            return false
        }
        return context.now.timeIntervalSince(lastActiveDate(for: bookmark, usage: usage)) >= context.cutoff
    }
}
