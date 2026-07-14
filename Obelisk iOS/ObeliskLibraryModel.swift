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
    private(set) var cloudSync: CloudSyncController?

    @ObservationIgnored private var store: BookmarkStore?
    @ObservationIgnored private var databaseWatchTask: Task<Void, Never>?
    @ObservationIgnored private let titleOptimizer = TitleOptimizer()

    static let autoArchiveEnabledKey = "autoArchiveIdleBookmarks"
    static let archiveAfterDaysKey = "archiveAfterDays"
    static let minimumArchiveDays = 3
    static let maximumArchiveDays = 30
    static let defaultArchiveDays = 30

    init(
        snapshot: ObeliskLibrarySnapshot = ObeliskLibrarySnapshot(),
        phase: Phase = .idle
    ) {
        self.snapshot = snapshot
        self.phase = phase
    }

    var bookmarks: [Bookmark] {
        let automaticArchive = automaticallyArchivedIDs
        return snapshot.bookmarks
            .filter { !$0.isHidden && $0.archivedAt == nil && !automaticArchive.contains($0.id) }
            .sorted(by: Self.bookmarkOrder)
    }

    var hiddenBookmarks: [Bookmark] {
        snapshot.bookmarks
            .filter(\.isHidden)
            .sorted(by: Self.bookmarkOrder)
    }

    var archivedBookmarks: [Bookmark] {
        let automaticArchive = automaticallyArchivedIDs
        return snapshot.bookmarks
            .filter { !$0.isHidden && ($0.archivedAt != nil || automaticArchive.contains($0.id)) }
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

            do {
                let configuration = try ObeliskServerConfiguration.load()
                let authClient = ObeliskAuthClient(configuration: configuration)
                let cloudSync = CloudSyncController(
                    database: store.database,
                    authClient: authClient
                )
                self.cloudSync = cloudSync
                Task { await cloudSync.start() }
            } catch {
                errorMessage = error.localizedDescription
            }
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
            let bookmark = try store.add(title: title, url: url, collectionID: collectionID)
            reload()
            Task { await applyAutomaticIntelligence(to: bookmark.id) }
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

    func setArchived(_ archived: Bool, bookmark: Bookmark) {
        guard let store else { return }
        do {
            try store.setArchived(archived, ids: [bookmark.id])
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshArchiveSettings() {
        reload()
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

    private func applyAutomaticIntelligence(to bookmarkID: Bookmark.ID) async {
        let defaults = UserDefaults.standard
        let intelligenceEnabled = defaults.object(forKey: "aiFeaturesEnabled") as? Bool ?? true
        let optimizeTitle = TitleOptimizationPreferences.autoOptimizeNewBookmarks(in: defaults)
        let autoGroup = BookmarkAutoGroupingPreferences.autoGroupNewBookmarks(in: defaults)
        guard intelligenceEnabled, optimizeTitle || autoGroup, let store else { return }

        do {
            if optimizeTitle,
               let bookmark = snapshot.bookmarks.first(where: { $0.id == bookmarkID }),
               TitleOptimizationPreferences.allowsOptimization(for: bookmark, defaults: defaults) {
                let optimized = try await titleOptimizer.optimize([
                    TitleOptimizationCandidate(
                        id: bookmark.id,
                        title: bookmark.title,
                        url: bookmark.url
                    )
                ])
                _ = try store.applyTitleOptimizations(optimized)
                reload()
            }

            guard autoGroup,
                  let bookmark = snapshot.bookmarks.first(where: { $0.id == bookmarkID }),
                  !bookmark.isHidden,
                  !bookmark.isPinned,
                  snapshot.collectionByBookmarkID[bookmarkID] == nil,
                  !snapshot.collections.isEmpty
            else {
                return
            }

            let suggestions = try await titleOptimizer.suggestGroups(
                for: [
                    BookmarkGroupingCandidate(
                        id: bookmark.id,
                        title: bookmark.title,
                        url: bookmark.url
                    )
                ],
                existingCollections: snapshot.collections.map {
                    BookmarkGroupingExistingCollection(id: $0.id, name: $0.name)
                }
            )
            guard let suggestion = suggestions[bookmarkID],
                  let collection = snapshot.collections.first(where: {
                      normalizedCollectionName($0.name) == normalizedCollectionName(suggestion)
                  })
            else {
                return
            }
            try store.setCollection(collection.id, for: [bookmarkID])
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func normalizedCollectionName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines.union(
                    CharacterSet(charactersIn: "\"'`")
                )
            )
            .lowercased()
    }

    private var automaticallyArchivedIDs: Set<Bookmark.ID> {
        guard UserDefaults.standard.bool(forKey: Self.autoArchiveEnabledKey) else {
            return []
        }

        let active = snapshot.bookmarks.filter { !$0.isHidden && $0.archivedAt == nil }
        let frequent = BookmarkUsageRanking.topFrequent(
            among: active,
            usage: snapshot.usageByBookmarkID,
            limit: 5
        )
        let frequentIDs = Set(frequent.map(\.id))
        let recent = BookmarkUsageRanking.recent(
            among: active.filter { !frequentIDs.contains($0.id) },
            limit: 5
        )
        let groupedIDs = Set(active.compactMap { bookmark in
            snapshot.collectionByBookmarkID[bookmark.id] == nil ? nil : bookmark.id
        })
        let pinnedIDs = Set(active.filter(\.isPinned).map(\.id))
        let protectedIDs = frequentIDs.union(recent.map(\.id)).union(groupedIDs).union(pinnedIDs)
        let storedDays = UserDefaults.standard.object(forKey: Self.archiveAfterDaysKey) as? Int
            ?? Self.defaultArchiveDays
        let days = min(Self.maximumArchiveDays, max(Self.minimumArchiveDays, storedDays))
        let cutoff = TimeInterval(days) * 86_400
        let now = Date()

        return Set(active.compactMap { bookmark in
            guard !protectedIDs.contains(bookmark.id) else { return nil }
            let lastActive = max(
                bookmark.createdAt,
                snapshot.usageByBookmarkID[bookmark.id]?.lastClickedAt ?? bookmark.createdAt
            )
            return now.timeIntervalSince(lastActive) >= cutoff ? bookmark.id : nil
        })
    }
}
