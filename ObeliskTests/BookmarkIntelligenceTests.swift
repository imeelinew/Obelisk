import Foundation
import ObeliskCore
import ObeliskData
import Testing
@testable import Obelisk

extension FeatureRegressionTests {
    @MainActor
    @Test func titleOptimizationQueueProcessesConsecutiveBookmarksSerially() async throws {
        try await withIntelligenceStore { store in
            let first = try store.add(title: "First", url: "https://first-queue.example")
            let second = try store.add(title: "Second", url: "https://second-queue.example")
            let optimizer = SerialTitleOptimizer()
            let model = BookmarksModel(store: store, titleOptimizer: optimizer)

            let firstTask = Task { await model.enqueueTitleOptimization(bookmarkIds: [first.id]) }
            await Task.yield()
            let secondTask = Task { await model.enqueueTitleOptimization(bookmarkIds: [second.id]) }
            let outcomes = await [firstTask.value, secondTask.value]

            #expect(outcomes[0].didChange)
            #expect(outcomes[1].didChange)
            #expect(optimizer.maximumConcurrentRequests == 1)
            #expect(optimizer.requestedIDs == [first.id, second.id])
            let bookmarks = try store.snapshot().bookmarks
            #expect(bookmarks.allSatisfy { $0.titleOptimizationState == .succeeded })
        }
    }

    @MainActor
    @Test func failedOptimizationPersistsAndCanBeRetried() async throws {
        try await withIntelligenceStore { store in
            let bookmark = try store.add(title: "Original", url: "https://retry.example")
            let optimizer = RetryTitleOptimizer()
            let model = BookmarksModel(store: store, titleOptimizer: optimizer)

            let failed = await model.enqueueTitleOptimization(bookmarkIds: [bookmark.id])
            #expect(failed.status == .failed)
            #expect(try store.snapshot().bookmarks.first?.titleOptimizationState == .failed)

            optimizer.shouldFail = false
            let retried = await model.enqueueTitleOptimization(bookmarkIds: [bookmark.id])
            #expect(retried.didChange)
            let updated = try #require(try store.snapshot().bookmarks.first)
            #expect(updated.title == "Optimized")
            #expect(updated.titleOptimizationState == .succeeded)
        }
    }

    @MainActor
    private func withIntelligenceStore(
        _ body: @MainActor (BookmarkStore) async throws -> Void
    ) async throws {
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

private final class SerialTitleOptimizer: TitleOptimizing, @unchecked Sendable {
    private let lock = NSLock()
    private var activeRequests = 0
    private(set) var maximumConcurrentRequests = 0
    private(set) var requestedIDs: [UUID] = []

    func optimize(_ candidates: [TitleOptimizationCandidate]) async throws -> [UUID: String] {
        lock.withLock {
            activeRequests += 1
            maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
            requestedIDs.append(contentsOf: candidates.map(\.id))
        }
        try await Task.sleep(for: .milliseconds(30))
        lock.withLock { activeRequests -= 1 }
        return Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, "Optimized \($0.title)") })
    }
}

private final class RetryTitleOptimizer: TitleOptimizing, @unchecked Sendable {
    var shouldFail = true

    func optimize(_ candidates: [TitleOptimizationCandidate]) async throws -> [UUID: String] {
        if shouldFail { throw TitleOptimizerError.requestFailed }
        return Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, "Optimized") })
    }
}
