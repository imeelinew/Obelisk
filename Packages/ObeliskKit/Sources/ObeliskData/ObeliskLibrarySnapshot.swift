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
