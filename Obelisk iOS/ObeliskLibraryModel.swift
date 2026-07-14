import Foundation
import ObeliskCore
import ObeliskData
import ObeliskSync
import Observation
import PowerSync

@MainActor
@Observable
final class ObeliskLibraryModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var snapshot = ObeliskLibrarySnapshot()
    private(set) var errorMessage: String?

    @ObservationIgnored private var store: BookmarkStore?
    @ObservationIgnored private var databaseWatchTask: Task<Void, Never>?

    init(
        snapshot: ObeliskLibrarySnapshot = ObeliskLibrarySnapshot(),
        phase: Phase = .idle
    ) {
        self.snapshot = snapshot
        self.phase = phase
    }

    var bookmarks: [Bookmark] {
        snapshot.bookmarks
            .filter { !$0.isHidden && $0.archivedAt == nil }
            .sorted(by: Self.bookmarkOrder)
    }

    var pinnedBookmarks: [Bookmark] {
        bookmarks.filter(\.isPinned)
    }

    var unpinnedBookmarks: [Bookmark] {
        bookmarks.filter { !$0.isPinned }
    }

    var collections: [BookmarkCollection] {
        snapshot.collections.sorted {
            if $0.sortOrder != $1.sortOrder {
                return $0.sortOrder < $1.sortOrder
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var recentlyOpenedBookmarks: [Bookmark] {
        bookmarks
            .filter { snapshot.usageByBookmarkID[$0.id] != nil }
            .sorted {
                let lhs = snapshot.usageByBookmarkID[$0.id]?.lastClickedAt ?? .distantPast
                let rhs = snapshot.usageByBookmarkID[$1.id]?.lastClickedAt ?? .distantPast
                if lhs != rhs { return lhs > rhs }
                return Self.bookmarkOrder($0, $1)
            }
    }

    func start() async {
        guard phase == .idle || isFailed else { return }
        phase = .loading
        do {
            let store = try await BookmarkStore.open(
                deviceID: ObeliskDeviceIdentity.current()
            )
            self.store = store
            reload()
            startDatabaseWatch(store.database)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func retry() async {
        databaseWatchTask?.cancel()
        databaseWatchTask = nil
        store = nil
        phase = .idle
        await start()
    }

    func bookmarks(in collectionID: UUID) -> [Bookmark] {
        bookmarks.filter { snapshot.collectionByBookmarkID[$0.id] == collectionID }
    }

    func collectionName(for bookmark: Bookmark) -> String? {
        guard let collectionID = snapshot.collectionByBookmarkID[bookmark.id] else {
            return nil
        }
        return collections.first(where: { $0.id == collectionID })?.name
    }

    func lastOpenedAt(for bookmark: Bookmark) -> Date? {
        snapshot.usageByBookmarkID[bookmark.id]?.lastClickedAt
    }

    func search(_ query: String) -> [Bookmark] {
        let terms = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        guard !terms.isEmpty else { return [] }

        return bookmarks.filter { bookmark in
            let searchableText = [bookmark.title, bookmark.url, collectionName(for: bookmark)]
                .compactMap { $0 }
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return terms.allSatisfy(searchableText.contains)
        }
    }

    func addBookmark(
        title: String,
        url: String,
        collectionID: UUID?
    ) -> String? {
        guard let store else { return "书签数据库尚未就绪" }
        do {
            try store.add(title: title, url: url, collectionID: collectionID)
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func createCollection(name: String) -> String? {
        guard let store else { return "书签数据库尚未就绪" }
        do {
            try store.createCollection(name: name)
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func recordUsage(for bookmark: Bookmark) {
        guard let store else { return }
        do {
            try store.database.recordUsage(bookmarkID: bookmark.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func reload() {
        guard let store else { return }
        do {
            snapshot = try store.snapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startDatabaseWatch(_ database: ObeliskDatabase) {
        databaseWatchTask?.cancel()
        let powerSync = database.powerSync
        databaseWatchTask = Task { [weak self] in
            do {
                let changes = try powerSync.watch(
                    sql: """
                    SELECT 'bookmark:' || id || ':' || updated_at AS version FROM bookmarks
                    UNION ALL
                    SELECT 'collection:' || id || ':' || updated_at AS version FROM collections
                    UNION ALL
                    SELECT 'usage:' || id || ':' || occurred_at AS version FROM usage_events
                    """,
                    parameters: []
                ) { cursor in
                    try cursor.getString(index: 0)
                }
                for try await _ in changes {
                    guard !Task.isCancelled else { return }
                    self?.reload()
                }
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private static func bookmarkOrder(_ lhs: Bookmark, _ rhs: Bookmark) -> Bool {
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
