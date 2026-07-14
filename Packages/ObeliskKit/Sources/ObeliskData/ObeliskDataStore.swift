import Foundation
import ObeliskCore

public struct ObeliskLibrarySnapshot: Equatable, Sendable {
    public var bookmarks: [Bookmark]
    public var collections: [BookmarkCollection]
    public var collectionByBookmarkID: [UUID: UUID]
    public var usageByBookmarkID: [UUID: UsageRecord]

    public init(
        bookmarks: [Bookmark] = [],
        collections: [BookmarkCollection] = [],
        collectionByBookmarkID: [UUID: UUID] = [:],
        usageByBookmarkID: [UUID: UsageRecord] = [:]
    ) {
        self.bookmarks = bookmarks
        self.collections = collections
        self.collectionByBookmarkID = collectionByBookmarkID
        self.usageByBookmarkID = usageByBookmarkID
    }
}

public protocol ObeliskDataStore: Sendable {
    func loadSnapshot() throws -> ObeliskLibrarySnapshot
    func saveBookmark(_ bookmark: Bookmark, collectionID: UUID?) throws
    func saveCollection(_ collection: BookmarkCollection) throws
    func deleteBookmark(id: UUID, at date: Date) throws
    func deleteCollection(id: UUID, at date: Date) throws
    func setCollection(_ collectionID: UUID?, for bookmarkIDs: Set<UUID>) throws
    func recordUsage(bookmarkID: UUID, at date: Date) throws
}
