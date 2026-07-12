import Foundation
@testable import Obelisk

struct BookmarkStateDatabase: Equatable {
    var version: Int = 2
    var hiddenIds: Set<UUID> = []
    var manualArchivedIds: Set<UUID> = []
    var pinnedIds: Set<UUID> = []
    var createdAtById: [UUID: Date] = [:]
    var titleOptimizedIds: Set<UUID> = []
    var originalTitleById: [UUID: String] = [:]
}

/// Test-only view over the vault payload's per-bookmark state. Production code
/// mutates bookmark state through `BookmarkStore`; this helper lets tests
/// read and write the same state as a `BookmarkStateDatabase` snapshot.
final class BookmarkStateStore {
    private(set) var rootDirectory: URL
    var fileURL: URL {
        ObeliskVaultStore(rootDirectory: rootDirectory).payloadURL
    }

    private var vaultStore: ObeliskVaultStore

    init(rootDirectory: URL = BookmarkStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
        self.vaultStore = ObeliskVaultStore(rootDirectory: rootDirectory)
    }

    func updateRootDirectory(_ rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        vaultStore = ObeliskVaultStore(rootDirectory: rootDirectory)
    }

    func invalidateCache() {
        vaultStore.invalidateCache()
    }

    func load() -> BookmarkStateDatabase {
        guard let payload = try? vaultStore.loadPayload() else {
            return BookmarkStateDatabase()
        }
        return Self.state(from: payload)
    }

    func save(_ state: BookmarkStateDatabase) throws {
        try vaultStore.updatePayload { payload in
            Self.apply(state, to: &payload)
        }
    }

    func update(_ body: (inout BookmarkStateDatabase) -> Void) throws {
        try vaultStore.updatePayload { payload in
            var state = Self.state(from: payload)
            let prior = state
            body(&state)
            guard state != prior else { return }
            Self.apply(state, to: &payload)
        }
    }

    private static func apply(_ state: BookmarkStateDatabase, to payload: inout ObeliskVaultPayload) {
        let validIds = Set(payload.bookmarks.map(\.id))
        let hiddenIds = state.hiddenIds.intersection(validIds)
        let manualArchivedIds = state.manualArchivedIds.intersection(validIds)
        let pinnedIds = state.pinnedIds.intersection(validIds)
        let titleOptimizedIds = state.titleOptimizedIds.intersection(validIds)

        payload.bookmarks = payload.bookmarks.map { bookmark in
            var bookmark = bookmark
            bookmark.createdAt = state.createdAtById[bookmark.id] ?? bookmark.createdAt
            bookmark.isHidden = hiddenIds.contains(bookmark.id)
            bookmark.titleOptimized = titleOptimizedIds.contains(bookmark.id)
            bookmark.archivedAt = manualArchivedIds.contains(bookmark.id)
                ? (bookmark.archivedAt ?? Date.distantPast)
                : nil
            bookmark.isPinned = pinnedIds.contains(bookmark.id)
                && !bookmark.isHidden
                && bookmark.archivedAt == nil
            bookmark.originalTitle = state.originalTitleById[bookmark.id] ?? bookmark.originalTitle
            return bookmark
        }
    }

    private static func state(from payload: ObeliskVaultPayload) -> BookmarkStateDatabase {
        BookmarkStateDatabase(
            version: 2,
            hiddenIds: Set(payload.bookmarks.filter(\.isHidden).map(\.id)),
            manualArchivedIds: Set(payload.bookmarks.filter { $0.archivedAt != nil }.map(\.id)),
            pinnedIds: Set(payload.bookmarks.filter { $0.isPinned && !$0.isHidden && $0.archivedAt == nil }.map(\.id)),
            createdAtById: Dictionary(
                uniqueKeysWithValues: payload.bookmarks.compactMap { bookmark in
                    guard bookmark.createdAt > .distantPast else { return nil }
                    return (bookmark.id, bookmark.createdAt)
                }
            ),
            titleOptimizedIds: Set(payload.bookmarks.filter(\.titleOptimized).map(\.id)),
            originalTitleById: Dictionary(
                uniqueKeysWithValues: payload.bookmarks.compactMap { bookmark in
                    guard let title = bookmark.originalTitle, !title.isEmpty else { return nil }
                    return (bookmark.id, title)
                }
            )
        )
    }
}
