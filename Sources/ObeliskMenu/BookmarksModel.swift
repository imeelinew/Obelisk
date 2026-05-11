import AppKit
import Foundation
import Observation
import ObeliskCore

@MainActor
@Observable
final class BookmarksModel {
    static let autoArchiveEnabledKey = "autoArchiveIdleBookmarks"
    static let archiveAfterDaysKey = "archiveAfterDays"
    static let minArchiveAfterDays = 3
    static let maxArchiveAfterDays = 30
    static let defaultArchiveAfterDays = 30

    private(set) var bookmarks: [Bookmark] = []
    /// Top-N most frecent bookmarks (≥3 clicks, decayed).
    private(set) var frequent: [Bookmark] = []
    /// Top-N by createdAt, excluding any already in `frequent`.
    private(set) var recent: [Bookmark] = []
    /// Remaining bookmarks not surfaced in the two groups above. Each
    /// bookmark appears in exactly one of `frequent` / `recent` / `others`,
    /// so a single List with selection can show all three sections without
    /// duplicate IDs.
    private(set) var others: [Bookmark] = []
    var errorMessage: String?
    private(set) var loadErrorMessage: String?

    /// Fired whenever the model's published state changes (reload or open).
    /// AppDelegate uses this to drive menubar rebuilds so menubar and the
    /// manage window stay in sync without recomputing groups twice.
    @ObservationIgnored var onChange: (() -> Void)?

    private let store: BookmarkStore
    private let usageStore: UsageStore
    private let titleOptimizer: TitleOptimizer
    private var frequentGroupLimit: Int
    private var recentGroupLimit: Int
    private(set) var isOptimizingTitles = false

    var rootDirectory: URL {
        store.rootDirectory
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
        self.titleOptimizer = TitleOptimizer(rootDirectory: store.rootDirectory)
        self.frequentGroupLimit = frequentGroupLimit
        self.recentGroupLimit = recentGroupLimit
        reload()
    }

    func migrateStorageRoot(to rootDirectory: URL) throws {
        let sourceDatabase = try store.load()
        let sourceUsage = usageStore.load()
        store.updateRootDirectory(rootDirectory)
        usageStore.updateRootDirectory(rootDirectory)
        titleOptimizer.updateRootDirectory(rootDirectory)

        let targetDatabase = (try? store.load()) ?? BookmarkDatabase()
        try store.save(mergedDatabase(targetDatabase, with: sourceDatabase))
        usageStore.saveAll(mergedUsage(usageStore.load(), with: sourceUsage))
        reload()
    }

    private func mergedDatabase(_ target: BookmarkDatabase, with source: BookmarkDatabase) -> BookmarkDatabase {
        var bookmarks = target.bookmarks
        var existingIds = Set(bookmarks.map(\.id))
        var existingURLs = Set(bookmarks.map { normalizedURL($0.url) })

        for bookmark in source.bookmarks {
            if let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
                if bookmark.createdAt >= bookmarks[idx].createdAt {
                    bookmarks[idx] = bookmark
                }
                continue
            }

            let urlKey = normalizedURL(bookmark.url)
            guard !existingIds.contains(bookmark.id), !existingURLs.contains(urlKey) else {
                continue
            }

            bookmarks.append(bookmark)
            existingIds.insert(bookmark.id)
            existingURLs.insert(urlKey)
        }

        bookmarks.sort {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return BookmarkDatabase(version: max(target.version, source.version), bookmarks: bookmarks)
    }

    private func mergedUsage(
        _ target: [UUID: UsageRecord],
        with source: [UUID: UsageRecord]
    ) -> [UUID: UsageRecord] {
        target.merging(source) { old, new in
            UsageRecord(
                count: max(old.count, new.count),
                lastClickedAt: max(old.lastClickedAt, new.lastClickedAt)
            )
        }
    }

    private func normalizedURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return raw.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? raw.lowercased()
    }

    func reload() {
        do {
            let all = try store.bookmarks()
            // Prune usage entries for deleted bookmarks. Cheap; only writes
            // when there are actually orphans.
            usageStore.cleanup(validIds: Set(all.map(\.id)))
            bookmarks = all
            let visibleBookmarks = visibleBookmarks(from: all)
            recomputeGroups(from: visibleBookmarks)
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

        recomputeGroups(from: visibleBookmarks(from: bookmarks))

        let changed = frequent.map(\.id) != priorFrequent
            || recent.map(\.id) != priorRecent
            || others.map(\.id) != priorOthers
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
        do {
            try store.add(title: title, url: url, isHidden: isHidden)
            reload()
            return nil
        } catch {
            return error.localizedDescription
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

    func setMenuGroupLimits(frequent: Int, recent: Int) {
        let nextFrequent = max(0, frequent)
        let nextRecent = max(0, recent)
        guard nextFrequent != frequentGroupLimit || nextRecent != recentGroupLimit else {
            return
        }
        frequentGroupLimit = nextFrequent
        recentGroupLimit = nextRecent
        recomputeGroups(from: visibleBookmarks(from: bookmarks))
        onChange?()
    }

    func delete(id: UUID) {
        delete(ids: [id])
    }

    func delete(ids: Set<UUID>) {
        do {
            try store.delete(ids: ids)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    enum TitleOptimizationScope {
        case visible
        case hidden
    }

    func optimizeAllTitles(scope: TitleOptimizationScope = .visible) async -> String {
        guard !isOptimizingTitles else {
            return "标题优化正在进行中"
        }

            let candidates = bookmarks
            .filter { bookmark in
                guard !bookmark.titleOptimized else { return false }
                switch scope {
                case .visible:
                    return !bookmark.isHidden && !isEffectivelyArchived(bookmark)
                case .hidden:
                    return bookmark.isHidden
                }
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

    private func recomputeGroups(from all: [Bookmark]) {
        let topFrequent = usageStore.topFrequent(among: all, limit: frequentGroupLimit)
        let frequentIds = Set(topFrequent.map(\.id))

        // Recent excludes anything already shown in "frequent" so each
        // bookmark only appears once.
        let recentCandidates = all.filter { !frequentIds.contains($0.id) }
        let topRecent = usageStore.recent(among: recentCandidates, limit: recentGroupLimit)

        let surfacedIds = frequentIds.union(topRecent.map(\.id))

        frequent = topFrequent
        recent = topRecent
        others = all.filter { !surfacedIds.contains($0.id) }
    }

    func isEffectivelyArchived(_ bookmark: Bookmark) -> Bool {
        isEffectivelyArchived(bookmark, in: bookmarks)
    }

    private struct AutoArchiveContext {
        var protectedIds: Set<Bookmark.ID>
        var cutoff: TimeInterval
        var now: Date
    }

    private func visibleBookmarks(from all: [Bookmark], now: Date = Date()) -> [Bookmark] {
        all.filter { !$0.isHidden && !isEffectivelyArchived($0, in: all, now: now) }
    }

    private func autoArchiveContext(in all: [Bookmark], now: Date = Date()) -> AutoArchiveContext? {
        guard autoArchiveEnabled else {
            return nil
        }

        let active = all.filter { !$0.isHidden && $0.archivedAt == nil }
        let topFrequent = usageStore.topFrequent(among: active, limit: frequentGroupLimit, now: now)
        let frequentIds = Set(topFrequent.map(\.id))
        let recentCandidates = active.filter { !frequentIds.contains($0.id) }
        let topRecent = usageStore.recent(among: recentCandidates, limit: recentGroupLimit)
        let protectedIds = frequentIds.union(topRecent.map(\.id))
        let cutoff = TimeInterval(archiveAfterDays) * 86_400

        return AutoArchiveContext(protectedIds: protectedIds, cutoff: cutoff, now: now)
    }

    private func lastActiveDate(for bookmark: Bookmark) -> Date {
        let createdAt = bookmark.createdAt == .distantPast ? .distantPast : bookmark.createdAt
        guard let lastClickedAt = usageStore.record(for: bookmark.id)?.lastClickedAt else {
            return createdAt
        }
        return max(createdAt, lastClickedAt)
    }

    private func isEffectivelyArchived(_ bookmark: Bookmark, in all: [Bookmark], now: Date = Date()) -> Bool {
        guard autoArchiveEnabled else {
            return false
        }
        guard !bookmark.isHidden else {
            return false
        }
        if bookmark.archivedAt != nil {
            return true
        }
        guard let context = autoArchiveContext(in: all, now: now),
              !context.protectedIds.contains(bookmark.id)
        else {
            return false
        }

        return context.now.timeIntervalSince(lastActiveDate(for: bookmark)) >= context.cutoff
    }
}
