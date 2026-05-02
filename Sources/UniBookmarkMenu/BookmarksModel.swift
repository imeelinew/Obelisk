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
    private let groupSize: Int

    init(store: BookmarkStore, usageStore: UsageStore, groupSize: Int = 5) {
        self.store = store
        self.usageStore = usageStore
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
            recomputeGroups(from: all)
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

    func add(title: String, url: String) -> Bool {
        do {
            try store.add(title: title, url: url)
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func update(_ bookmark: Bookmark) -> Bool {
        do {
            try store.update(bookmark)
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(id: UUID) {
        do {
            try store.delete(id: id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Records a real "navigation" use of a bookmark — only menubar clicks
    /// should call this. The manage window's "open" action is a preview /
    /// integrity check, not usage, and must bypass this method to avoid
    /// polluting frecency.
    func openBookmark(_ bookmark: Bookmark) {
        guard let url = URL(string: bookmark.url) else { return }
        usageStore.record(id: bookmark.id)
        recomputeGroups(from: bookmarks)
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
