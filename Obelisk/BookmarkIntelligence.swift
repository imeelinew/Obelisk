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

    var didChange: Bool { status == .changed }

    var summary: String {
        if status == .changed {
            if optimizedTitles.count == 1, let title = optimizedTitles.first {
                return "标题「\(title)」"
            }
            return "优化标题 \(optimizedTitles.count) 个"
        }
        return message
    }
}

/// Owns title optimization execution without retaining the library model
/// The model remains the source of bookmarks and the boundary for local-first writes
@MainActor
@Observable
final class BookmarkIntelligence {
    private let titleOptimizer: any TitleOptimizing

    private(set) var isOptimizingTitles = false

    init(titleOptimizer: (any TitleOptimizing)? = nil) {
        self.titleOptimizer = titleOptimizer ?? TitleOptimizer()
    }

    func optimizeTitleDetails(
        in model: BookmarksModel,
        bookmarkIds: Set<UUID>
    ) async -> TitleOptimizationOutcome {
        guard UserDefaults.standard.object(forKey: BookmarksModel.aiFeaturesEnabledKey) as? Bool ?? true else {
            return TitleOptimizationOutcome(
                message: "Intelligence 功能已关闭",
                optimizedTitles: [],
                status: .failed
            )
        }

        guard !isOptimizingTitles else {
            return TitleOptimizationOutcome(
                message: "书签优化正在进行中",
                optimizedTitles: [],
                status: .failed
            )
        }

        let candidates = model.bookmarks
            .filter { bookmark in
                bookmarkIds.contains(bookmark.id)
                    && bookmark.titleOptimizationState != .succeeded
                    && TitleOptimizationPreferences.allowsOptimization(for: bookmark)
            }
            .map {
                TitleOptimizationCandidate(id: $0.id, title: $0.title, url: $0.url)
            }

        guard !candidates.isEmpty else {
            return TitleOptimizationOutcome(message: "没有需要优化的标题", optimizedTitles: [])
        }

        isOptimizingTitles = true
        defer { isOptimizingTitles = false }

        let candidateIDs = Set(candidates.map(\.id))
        do {
            let optimizedTitles = try await titleOptimizer.optimize(candidates)
                .filter { candidateIDs.contains($0.key) }
            let optimizedIDs = Set(optimizedTitles.keys)
            let failedIDs = candidateIDs.subtracting(optimizedIDs)
            let count = try model.applyTitleOptimizations(optimizedTitles)
            if !failedIDs.isEmpty {
                try model.markTitleOptimizationFailed(failedIDs)
            }
            model.reload()

            guard count > 0 else {
                return TitleOptimizationOutcome(
                    message: "标题优化失败",
                    optimizedTitles: [],
                    status: .failed
                )
            }
            return TitleOptimizationOutcome(
                message: failedIDs.isEmpty
                    ? "已优化 \(count) 个标题"
                    : "已优化 \(count) 个标题，\(failedIDs.count) 个失败",
                optimizedTitles: optimizedDisplayTitles(
                    in: model,
                    for: candidates,
                    optimizedTitles: optimizedTitles
                ),
                status: .changed
            )
        } catch {
            try? model.markTitleOptimizationFailed(candidateIDs)
            model.reload()
            return TitleOptimizationOutcome(
                message: error.localizedDescription,
                optimizedTitles: [],
                status: .failed
            )
        }
    }

    private func optimizedDisplayTitles(
        in model: BookmarksModel,
        for candidates: [TitleOptimizationCandidate],
        optimizedTitles: [UUID: String]
    ) -> [String] {
        let bookmarksByID = Dictionary(uniqueKeysWithValues: model.bookmarks.map { ($0.id, $0) })
        return candidates.compactMap { candidate in
            guard
                let proposedTitle = optimizedTitles[candidate.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !proposedTitle.isEmpty,
                let bookmark = bookmarksByID[candidate.id],
                bookmark.titleOptimizationState == .succeeded
            else {
                return nil
            }
            return bookmark.title
        }
    }
}
