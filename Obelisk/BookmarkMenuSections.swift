import Foundation
import ObeliskCore

enum BookmarkMenuSectionID: Hashable, Identifiable, Sendable {
    case pinned
    case recent
    case collection(UUID)
    case ungrouped

    var id: String { storageValue }

    var storageValue: String {
        switch self {
        case .pinned: return "pinned"
        case .recent: return "recent"
        case .collection(let id): return "collection:\(id.uuidString)"
        case .ungrouped: return "ungrouped"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "pinned":
            self = .pinned
        case "recent":
            self = .recent
        case "ungrouped":
            self = .ungrouped
        default:
            guard
                storageValue.hasPrefix("collection:"),
                let id = UUID(uuidString: String(storageValue.dropFirst("collection:".count)))
            else {
                return nil
            }
            self = .collection(id)
        }
    }
}

struct BookmarkMenuOrderItem: Identifiable {
    var id: BookmarkMenuSectionID
    var title: String
    var systemImage: String
}

enum BookmarkMenuSectionOrder {
    static let storageKey = "menuBarSectionOrder"

    static func encoded(_ ids: [BookmarkMenuSectionID]) -> String {
        ids.map(\.storageValue).joined(separator: "\n")
    }

    static func order(
        collections: [BookmarkCollection],
        rawValue: String? = UserDefaults.standard.string(forKey: storageKey)
    ) -> [BookmarkMenuSectionID] {
        let defaultOrder = defaultOrder(collections: collections)
        guard let rawValue, !rawValue.isEmpty else {
            return defaultOrder
        }

        let validCollectionIds = Set(collections.map(\.id))
        var seen = Set<BookmarkMenuSectionID>()
        var result: [BookmarkMenuSectionID] = []
        for id in rawValue.split(separator: "\n").compactMap({ BookmarkMenuSectionID(storageValue: String($0)) }) {
            guard isValid(id, validCollectionIds: validCollectionIds), !seen.contains(id) else {
                continue
            }
            result.append(id)
            seen.insert(id)
        }

        insertMissingStaticItems(into: &result)

        let missingCollections = collections
            .map { BookmarkMenuSectionID.collection($0.id) }
            .filter { !seen.contains($0) && !result.contains($0) }
        let insertionIndex = collectionInsertionIndex(in: result)
        result.insert(contentsOf: missingCollections, at: insertionIndex)

        return result
    }

    static func items(
        collections: [BookmarkCollection],
        rawValue: String? = UserDefaults.standard.string(forKey: storageKey)
    ) -> [BookmarkMenuOrderItem] {
        let collectionNames = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0.name) })
        return order(collections: collections, rawValue: rawValue).map { id in
            switch id {
            case .pinned:
                return BookmarkMenuOrderItem(id: id, title: "置顶".obeliskLocalized, systemImage: "pin.fill")
            case .recent:
                return BookmarkMenuOrderItem(id: id, title: "最近添加".obeliskLocalized, systemImage: "clock.arrow.circlepath")
            case .collection(let collectionId):
                return BookmarkMenuOrderItem(
                    id: id,
                    title: collectionNames[collectionId] ?? "分组".obeliskLocalized,
                    systemImage: "folder.fill"
                )
            case .ungrouped:
                return BookmarkMenuOrderItem(id: id, title: "未分组".obeliskLocalized, systemImage: "bookmark.fill")
            }
        }
    }

    static func moving(
        _ sourceIDs: [BookmarkMenuSectionID],
        before destinationID: BookmarkMenuSectionID?,
        in order: [BookmarkMenuSectionID]
    ) -> [BookmarkMenuSectionID] {
        let sourceSet = Set(sourceIDs)
        guard !sourceSet.isEmpty else { return order }
        if let destinationID, sourceSet.contains(destinationID) {
            return order
        }

        let movedIDs = order.filter(sourceSet.contains)
        guard !movedIDs.isEmpty else { return order }

        var result = order.filter { !sourceSet.contains($0) }
        let insertionIndex: Int
        if let destinationID {
            guard let destinationIndex = result.firstIndex(of: destinationID) else {
                return order
            }
            insertionIndex = destinationIndex
        } else {
            insertionIndex = result.endIndex
        }

        result.insert(contentsOf: movedIDs, at: insertionIndex)
        return result
    }

    private static func defaultOrder(collections: [BookmarkCollection]) -> [BookmarkMenuSectionID] {
        [.pinned, .recent] + collections.map { .collection($0.id) } + [.ungrouped]
    }

    private static func isValid(_ id: BookmarkMenuSectionID, validCollectionIds: Set<UUID>) -> Bool {
        switch id {
        case .pinned, .recent, .ungrouped:
            return true
        case .collection(let collectionId):
            return validCollectionIds.contains(collectionId)
        }
    }

    private static func insertMissingStaticItems(into result: inout [BookmarkMenuSectionID]) {
        if !result.contains(.pinned) {
            result.insert(.pinned, at: 0)
        }
        if !result.contains(.recent) {
            let index = result.firstIndex(of: .pinned).map { $0 + 1 } ?? 0
            result.insert(.recent, at: min(index, result.count))
        }
        if !result.contains(.ungrouped) {
            result.append(.ungrouped)
        }
    }

    private static func collectionInsertionIndex(in result: [BookmarkMenuSectionID]) -> Int {
        if let recentIndex = result.firstIndex(of: .recent),
           let ungroupedIndex = result.firstIndex(of: .ungrouped),
           recentIndex < ungroupedIndex {
            return ungroupedIndex
        }
        if let recentIndex = result.firstIndex(of: .recent) {
            return min(recentIndex + 1, result.count)
        }
        return result.firstIndex(of: .ungrouped) ?? result.count
    }
}

struct BookmarkMenuRenderSection: Identifiable {
    enum Presentation {
        case inline
        case reference
        case submenu
    }

    var id: BookmarkMenuSectionID
    var title: String
    var bookmarks: [Bookmark]
    var presentation: Presentation
}

struct BookmarkMenuSections {
    var pinned: [BookmarkListSection]
    var recent: [Bookmark]
    var collections: [BookmarkListSection]
    var ungrouped: [BookmarkListSection]

    var library: [BookmarkListSection] {
        collections + ungrouped
    }

    var isEmpty: Bool {
        pinned.isEmpty && recent.isEmpty && collections.isEmpty && ungrouped.isEmpty
    }

    func renderSections(order: [BookmarkMenuSectionID]) -> [BookmarkMenuRenderSection] {
        let collectionSections = Dictionary(
            uniqueKeysWithValues: collections.compactMap { section -> (UUID, BookmarkListSection)? in
                guard let collectionId = section.collectionId else { return nil }
                return (collectionId, section)
            }
        )

        return order.compactMap { id in
            switch id {
            case .pinned:
                guard let section = pinned.first, let title = section.title, !section.bookmarks.isEmpty else {
                    return nil
                }
                return BookmarkMenuRenderSection(
                    id: id,
                    title: title,
                    bookmarks: section.bookmarks,
                    presentation: .inline
                )
            case .recent:
                guard !recent.isEmpty else { return nil }
                return BookmarkMenuRenderSection(
                    id: id,
                    title: "\("最近添加".obeliskLocalized) (\(recent.count))",
                    bookmarks: recent,
                    presentation: .reference
                )
            case .collection(let collectionId):
                guard
                    let section = collectionSections[collectionId],
                    let title = section.title,
                    !section.bookmarks.isEmpty
                else {
                    return nil
                }
                return BookmarkMenuRenderSection(
                    id: id,
                    title: title,
                    bookmarks: section.bookmarks,
                    presentation: .submenu
                )
            case .ungrouped:
                guard let section = ungrouped.first, let title = section.title, !section.bookmarks.isEmpty else {
                    return nil
                }
                return BookmarkMenuRenderSection(
                    id: id,
                    title: title,
                    bookmarks: section.bookmarks,
                    presentation: .submenu
                )
            }
        }
    }
}

