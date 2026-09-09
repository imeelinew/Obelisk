import Foundation
import ObeliskCore
import ObeliskData
import Observation
import Testing
@testable import Obelisk

// Join the existing serialized suite because Intelligence preferences use standard defaults.
extension FeatureRegressionTests {
    @MainActor
    @Test func intelligenceBusyStateRemainsObservableAndRejectsCombinedReentry() async throws {
        try await withIntelligenceStore { store in
            let bookmark = try store.add(title: "Original", url: "https://busy.example")
            let optimizer = InspectingIntelligenceOptimizer()
            let model = BookmarksModel(store: store, titleOptimizer: optimizer, groupOptimizer: optimizer)
            let changes = IntelligenceObservationCount()
            withObservationTracking {
                _ = model.isOptimizingBookmarks
            } onChange: {
                changes.increment()
            }
            optimizer.titleAction = { [weak model] _ in
                let model = try #require(model)
                #expect(model.isOptimizingBookmarks)
                #expect(model.isOptimizingTitles)
                #expect(!model.isAutoGroupingBookmarks)
                #expect(changes.value == 1)
                let titles = await model.optimizeTitleDetails(bookmarkIds: [bookmark.id])
                let grouping = await model.autoGroupBookmarks()
                let combined = await model.optimizeBookmarks(options: .init(optimizeTitles: true, autoGroup: true))
                #expect(titles.status == .failed)
                #expect(grouping.status == .failed)
                #expect(combined.titleOptimization?.status == .failed)
                #expect(combined.autoGrouping?.status == .failed)
                // Observe the reset separately: Observation subscriptions are one-shot.
                withObservationTracking {
                    _ = model.isOptimizingTitles
                } onChange: {
                    changes.increment()
                }
                throw CancellationError()
            }
            let outcome = await model.optimizeBookmarks(options: .init(optimizeTitles: true, autoGroup: false))
            #expect(outcome.titleOptimization?.status == .failed)
            #expect(!model.isOptimizingBookmarks)
            #expect(!model.isOptimizingTitles)
            #expect(!model.isAutoGroupingBookmarks)
            #expect(changes.value == 2)
            #expect(try store.snapshot().bookmarks.first?.title == "Original")
        }
    }

    @MainActor
    @Test func intelligenceStandaloneStepsCanOverlapAndCommitLocally() async throws {
        try await withIntelligenceStore { store in
            let bookmark = try store.add(title: "Original", url: "https://overlap.example")
            try store.createCollection(name: "Reading")
            let optimizer = InspectingIntelligenceOptimizer()
            let model = BookmarksModel(store: store, titleOptimizer: optimizer, groupOptimizer: optimizer)
            optimizer.titleAction = { [weak model] _ in
                let model = try #require(model)
                #expect(model.isOptimizingTitles)
                #expect(!model.isOptimizingBookmarks)
                let grouping = await model.autoGroupBookmarks()
                #expect(grouping.status == .changed)
                #expect(model.isOptimizingTitles)
                #expect(!model.isAutoGroupingBookmarks)
                return [bookmark.id: "Optimized"]
            }
            optimizer.groupAction = { [weak model] candidates in
                let model = try #require(model)
                #expect(model.isOptimizingTitles)
                #expect(model.isAutoGroupingBookmarks)
                #expect(candidates.map(\.title) == ["Original"])
                let duplicate = await model.autoGroupBookmarks()
                #expect(duplicate.status == .failed)
                return [bookmark.id: "Reading"]
            }
            let result = await model.optimizeTitleDetails(bookmarkIds: [bookmark.id])
            #expect(result.optimizedTitles == ["Optimized"])
            #expect(!model.isOptimizingTitles)
            let snapshot = try store.snapshot()
            #expect(snapshot.bookmarks.first?.title == "Optimized")
            #expect(snapshot.collectionByBookmarkID[bookmark.id] == snapshot.collections.first?.id)
        }
    }

    @MainActor
    @Test func intelligenceRechecksGroupingEligibilityAfterOptimizerReturns() async throws {
        try await withIntelligenceStore { store in
            let bookmark = try store.add(title: "Original", url: "https://recheck.example")
            try store.createCollection(name: "Reading")
            let optimizer = InspectingIntelligenceOptimizer()
            let model = BookmarksModel(store: store, groupOptimizer: optimizer)
            optimizer.groupAction = { [weak model] candidates in
                let model = try #require(model)
                #expect(candidates.map(\.id) == [bookmark.id])
                #expect(model.setHidden(true, for: bookmark.id) == nil)
                await Task.yield()
                return [bookmark.id: "Reading"]
            }
            let outcome = await model.autoGroupBookmarks()
            #expect(outcome.status == .noChange)
            #expect(outcome.groupedCount == 0)
            #expect(!model.isAutoGroupingBookmarks)
            #expect(try store.snapshot().collectionByBookmarkID[bookmark.id] == nil)
        }
    }

    @MainActor
    private func withIntelligenceStore(_ body: @MainActor (BookmarkStore) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: BookmarksModel.aiFeaturesEnabledKey)
        defaults.set(true, forKey: BookmarksModel.aiFeaturesEnabledKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IntelligenceTests-\(UUID())")
        defer {
            if let previous {
                defaults.set(previous, forKey: BookmarksModel.aiFeaturesEnabledKey)
            } else {
                defaults.removeObject(forKey: BookmarksModel.aiFeaturesEnabledKey)
            }
            try? FileManager.default.removeItem(at: root)
        }
        let store = try BookmarkStore.open(rootDirectory: root, deviceID: UUID())
        try await body(store)
    }
}

@MainActor
private final class InspectingIntelligenceOptimizer: TitleOptimizing, BookmarkGroupingOptimizing {
    var titleAction: (@MainActor ([TitleOptimizationCandidate]) async throws -> [UUID: String])?
    var groupAction: (@MainActor ([BookmarkGroupingCandidate]) async throws -> [UUID: String])?

    func optimize(_ candidates: [TitleOptimizationCandidate]) async throws -> [UUID: String] {
        try await titleAction?(candidates) ?? [:]
    }

    func suggestGroups(
        for candidates: [BookmarkGroupingCandidate],
        existingCollections: [BookmarkGroupingExistingCollection]
    ) async throws -> [UUID: String] {
        try await groupAction?(candidates) ?? [:]
    }
}

private final class IntelligenceObservationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
