import Foundation
import ObeliskCore
import Observation

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

/// Owns Intelligence execution and observable activity, without retaining the library model.
/// The model remains the source of bookmarks and the boundary for local-first writes.
@MainActor
@Observable
final class BookmarkIntelligence {
    private let titleOptimizer: any TitleOptimizing
    private let groupOptimizer: any BookmarkGroupingOptimizing

    private(set) var isOptimizingTitles = false
    private(set) var isAutoGroupingBookmarks = false
    private(set) var isOptimizingBookmarks = false

    init(
        titleOptimizer: (any TitleOptimizing)? = nil,
        groupOptimizer: (any BookmarkGroupingOptimizing)? = nil
    ) {
        let defaultOptimizer = TitleOptimizer()
        self.titleOptimizer = titleOptimizer ?? defaultOptimizer
        self.groupOptimizer = groupOptimizer ?? defaultOptimizer
    }

    func autoGroupBookmarks(in model: BookmarksModel, bookmarkIds: Set<UUID> = []) async -> BookmarkAutoGroupingOutcome {
        guard UserDefaults.standard.object(forKey: BookmarksModel.aiFeaturesEnabledKey) as? Bool ?? true else {
            return Self.emptyAutoGroupingOutcome(message: "Intelligence 功能已关闭", status: .failed)
        }

        guard !isOptimizingBookmarks, !isAutoGroupingBookmarks else {
            return Self.emptyAutoGroupingOutcome(message: "书签优化正在进行中", status: .failed)
        }

        return await autoGroupBookmarksStep(in: model, bookmarkIds: bookmarkIds)
    }

    private func autoGroupBookmarksStep(in model: BookmarksModel, bookmarkIds: Set<UUID>) async -> BookmarkAutoGroupingOutcome {
        let candidates = model.autoGroupingCandidates(scopedTo: bookmarkIds)
        guard !candidates.isEmpty else {
            return Self.emptyAutoGroupingOutcome(message: "没有需要自动分组的书签")
        }
        guard !model.collections.isEmpty else {
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
                existingCollections: model.collections.map {
                    BookmarkGroupingExistingCollection(id: $0.id, name: $0.name)
                }
            )
            let currentCandidates = model.autoGroupingCandidates(scopedTo: Set(candidates.map(\.id)))
            guard !currentCandidates.isEmpty else {
                return Self.emptyAutoGroupingOutcome(message: "没有需要自动分组的书签")
            }
            let result = try model.applyAutoGroupingSuggestions(suggestions, to: currentCandidates)
            model.reload()
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

    func optimizeTitleDetails(in model: BookmarksModel, bookmarkIds: Set<UUID>) async -> TitleOptimizationOutcome {
        guard UserDefaults.standard.object(forKey: BookmarksModel.aiFeaturesEnabledKey) as? Bool ?? true else {
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

        return await optimizeTitleDetailsStep(in: model, bookmarkIds: bookmarkIds)
    }

    private func optimizeTitleDetailsStep(in model: BookmarksModel, bookmarkIds: Set<UUID>) async -> TitleOptimizationOutcome {
        let candidates = model.bookmarks
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
            let count = try model.applyTitleOptimizations(optimizedTitles)
            model.reload()
            if count == 0 {
                return TitleOptimizationOutcome(message: "没有标题被更新", optimizedTitles: [])
            }
            return TitleOptimizationOutcome(
                message: "已优化 \(count) 个标题",
                optimizedTitles: optimizedDisplayTitles(in: model, for: candidates, optimizedTitles: optimizedTitles),
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
        in model: BookmarksModel,
        bookmarkIds: Set<UUID> = [],
        options: BookmarkIntelligenceOptimizationOptions
    ) async -> BookmarkIntelligenceOptimizationOutcome {
        guard UserDefaults.standard.object(forKey: BookmarksModel.aiFeaturesEnabledKey) as? Bool ?? true else {
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
            ? Set(model.bookmarks.map(\.id))
            : bookmarkIds
        let titleOutcome = options.optimizeTitles
            ? await optimizeTitleDetailsStep(in: model, bookmarkIds: scopedBookmarkIds)
            : nil
        let groupingOutcome = options.autoGroup
            ? await autoGroupBookmarksStep(in: model, bookmarkIds: bookmarkIds)
            : nil

        return BookmarkIntelligenceOptimizationOutcome(
            titleOptimization: titleOutcome,
            autoGrouping: groupingOutcome
        )
    }

    private func optimizedDisplayTitles(
        in model: BookmarksModel,
        for candidates: [TitleOptimizationCandidate],
        optimizedTitles: [UUID: String]
    ) -> [String] {
        let bookmarksById = Dictionary(uniqueKeysWithValues: model.bookmarks.map { ($0.id, $0) })
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

}
