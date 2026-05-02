import CoreSpotlight
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import UniBookmarkCore

/// Indexes bookmarks into the user's CoreSpotlight index so they appear in
/// system search. Each bookmark becomes a `CSSearchableItem` keyed by its
/// UUID under the domain `local.elidev.UniBookmark.bookmarks`.
///
/// Re-indexing is full-replace by domain; we don't track diffs because the
/// bookmark set is tiny and Spotlight handles the deltas internally.
@MainActor
final class SpotlightIndexer {
    private let domainIdentifier = "local.elidev.UniBookmark.bookmarks"
    private let rootDirectory: URL
    private var reindexGeneration = 0
    private var reindexTask: Task<Void, Never>?

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    private var faviconDirectory: URL {
        rootDirectory.appendingPathComponent("favicons", isDirectory: true)
    }

    func reindexAll(_ bookmarks: [Bookmark]) {
        let items = bookmarks.map { searchableItem(for: $0) }
        reindexGeneration &+= 1
        let generation = reindexGeneration
        let previousTask = reindexTask
        reindexTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard let self, generation == self.reindexGeneration else {
                return
            }

            let index = CSSearchableIndex.default()
            // `deleteAllSearchableItems` wipes everything this app has ever
            // indexed — including orphan items left over by earlier
            // development iterations under different domains. Cheap (the
            // index is small) and guarantees a clean slate before re-adding.
            try? await index.deleteAllSearchableItems()
            guard generation == self.reindexGeneration else {
                return
            }
            try? await index.indexSearchableItems(items)
        }
    }

    /// Wipes our domain. README documents this as the cleanup hook.
    func deleteAll() {
        CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { _ in }
    }

    /// Reverse of the `uniqueIdentifier` we set on each item.
    func bookmarkID(from identifier: String) -> UUID? {
        UUID(uuidString: identifier)
    }

    /// AppDelegate uses this name in the older `application(_:continue:)`
    /// path. Kept as a convenience alias.
    func bookmarkID(for identifier: String) -> UUID? {
        bookmarkID(from: identifier)
    }

    private func searchableItem(for bookmark: Bookmark) -> CSSearchableItem {
        // `UTType.url` (a.k.a. `public.url`) gives Spotlight a sensible,
        // localizable category. `UTType.item` (the root of the UTI tree)
        // shows up under low-resolution fallback labels like "item-0".
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.url)
        attributes.title = bookmark.title
        attributes.displayName = bookmark.title
        attributes.contentDescription = bookmark.url
        if let url = URL(string: bookmark.url) {
            attributes.url = url
            attributes.keywords = [bookmark.title, url.host ?? bookmark.url]
        } else {
            attributes.keywords = [bookmark.title]
        }
        if let data = faviconData(for: bookmark.url) {
            attributes.thumbnailData = data
        }
        return CSSearchableItem(
            uniqueIdentifier: bookmark.id.uuidString,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
    }

    private func faviconData(for urlString: String) -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        for key in faviconCacheKeys(for: url) {
            let path = faviconDirectory.appendingPathComponent("\(key).png")
            if let data = try? Data(contentsOf: path) {
                return data
            }
        }
        return nil
    }

    /// Mirrors `FaviconLoader.cacheKey`: SHA256(host[:port]).prefix(8) as hex.
    /// Returned as an array so we have room to add legacy string-replace keys
    /// here later if needed for migration.
    private func faviconCacheKeys(for url: URL) -> [String] {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host?.lowercased()
        else { return [] }
        let identity = components.port.map { "\(host):\($0)" } ?? host
        let digest = SHA256.hash(data: Data(identity.utf8))
        let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return [key]
    }
}
