import Foundation
import ObeliskCore

public struct ObeliskLibrarySnapshot: Equatable, Sendable {
    public var bookmarks: [Bookmark]
    public var collections: [BookmarkCollection]
    public var collectionByBookmarkID: [UUID: UUID]
    public var usageByBookmarkID: [UUID: UsageRecord]
    public var browserHistory: [BrowserHistoryRecord]
    public var browserHistorySettings: BrowserHistorySettings?

    public init(
        bookmarks: [Bookmark] = [],
        collections: [BookmarkCollection] = [],
        collectionByBookmarkID: [UUID: UUID] = [:],
        usageByBookmarkID: [UUID: UsageRecord] = [:],
        browserHistory: [BrowserHistoryRecord] = [],
        browserHistorySettings: BrowserHistorySettings? = nil
    ) {
        self.bookmarks = bookmarks
        self.collections = collections
        self.collectionByBookmarkID = collectionByBookmarkID
        self.usageByBookmarkID = usageByBookmarkID
        self.browserHistory = browserHistory
        self.browserHistorySettings = browserHistorySettings
    }
}
