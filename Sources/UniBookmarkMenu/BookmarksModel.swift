import AppKit
import Foundation
import Observation
import UniBookmarkCore

@MainActor
@Observable
final class BookmarksModel {
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
    private let spotlightIndexer: SpotlightIndexer?
    private let titleOptimizer: TitleOptimizer
    private let groupSize: Int
    private(set) var isOptimizingTitles = false

    init(
        store: BookmarkStore,
        usageStore: UsageStore,
        spotlightIndexer: SpotlightIndexer? = nil,
        groupSize: Int = 5
    ) {
        self.store = store
        self.usageStore = usageStore
        self.spotlightIndexer = spotlightIndexer
        self.titleOptimizer = TitleOptimizer(rootDirectory: store.rootDirectory)
        self.groupSize = groupSize
        reload()
    }

    func reload() {
        do {
            let all = try store.bookmarks()
            bookmarks = all
            // Prune usage entries for deleted bookmarks. Cheap; only writes
            // when there are actually orphans.
            usageStore.cleanup(validIds: Set(all.map(\.id)))
            let visibleBookmarks = all.filter { !$0.isHidden }
            recomputeGroups(from: visibleBookmarks)
            spotlightIndexer?.reindexAll(visibleBookmarks)
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

    func optimizeAllTitles() async -> String {
        guard !isOptimizingTitles else {
            return "标题优化正在进行中"
        }

        let candidates = bookmarks
            .filter { !$0.titleOptimized && !$0.isHidden }
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
        usageStore.record(id: bookmark.id)
        recomputeGroups(from: bookmarks.filter { !$0.isHidden })
        NSWorkspace.shared.open(url)
        onChange?()
    }

    private func recomputeGroups(from all: [Bookmark]) {
        let topFrequent = usageStore.topFrequent(among: all, limit: groupSize)
        let frequentIds = Set(topFrequent.map(\.id))

        // Recent excludes anything already shown in "frequent" so each
        // bookmark only appears once.
        let recentCandidates = all.filter { !frequentIds.contains($0.id) }
        let topRecent = usageStore.recent(among: recentCandidates, limit: groupSize)

        let surfacedIds = frequentIds.union(topRecent.map(\.id))

        frequent = topFrequent
        recent = topRecent
        others = all.filter { !surfacedIds.contains($0.id) }
    }
}
