import Foundation
import ObeliskCore

enum BookmarkMenuSectionID: Hashable, Identifiable, Sendable {
    case recent
    case collection(UUID)
    case ungrouped

    var id: String { storageValue }

    var storageValue: String {
        switch self {
        case .recent: "recent"
        case .collection(let id): "collection:\(id.uuidString.lowercased())"
        case .ungrouped: "ungrouped"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "recent": self = .recent
        case "ungrouped": self = .ungrouped
        default:
            guard
                storageValue.hasPrefix("collection:"),
                let id = UUID(uuidString: String(storageValue.dropFirst("collection:".count)))
            else { return nil }
            self = .collection(id)
        }
    }
}

struct BookmarkMenuOrderItem: Identifiable, Equatable {
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
        let defaultOrder = [.recent] + collections.map { BookmarkMenuSectionID.collection($0.id) } + [.ungrouped]
        guard let rawValue, !rawValue.isEmpty else { return defaultOrder }

        let validCollectionIDs = Set(collections.map(\.id))
        var seen = Set<BookmarkMenuSectionID>()
        var result = rawValue.split(separator: "\n").compactMap {
            BookmarkMenuSectionID(storageValue: String($0))
        }.filter { id in
            let isValid = switch id {
            case .recent, .ungrouped: true
            case .collection(let collectionID): validCollectionIDs.contains(collectionID)
            }
            return isValid && seen.insert(id).inserted
        }

        if !result.contains(.recent) { result.insert(.recent, at: 0) }
        if !result.contains(.ungrouped) { result.append(.ungrouped) }

        let missingCollections = collections
            .map { BookmarkMenuSectionID.collection($0.id) }
            .filter { !result.contains($0) }
        let insertionIndex = result.firstIndex(of: .ungrouped) ?? result.endIndex
        result.insert(contentsOf: missingCollections, at: insertionIndex)
        return result
    }

    static func items(
        collections: [BookmarkCollection],
        rawValue: String? = UserDefaults.standard.string(forKey: storageKey)
    ) -> [BookmarkMenuOrderItem] {
        let names = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0.name) })
        return order(collections: collections, rawValue: rawValue).map { id in
            switch id {
            case .recent:
                BookmarkMenuOrderItem(id: id, title: "最近添加".obeliskLocalized, systemImage: "clock.arrow.circlepath")
            case .collection(let collectionID):
                BookmarkMenuOrderItem(id: id, title: names[collectionID] ?? "分组".obeliskLocalized, systemImage: "folder.fill")
            case .ungrouped:
                BookmarkMenuOrderItem(id: id, title: "未分组".obeliskLocalized, systemImage: "bookmark.fill")
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
        if let destinationID, sourceSet.contains(destinationID) { return order }

        let movedIDs = order.filter(sourceSet.contains)
        guard !movedIDs.isEmpty else { return order }
        var result = order.filter { !sourceSet.contains($0) }
        let insertionIndex: Int
        if let destinationID, let index = result.firstIndex(of: destinationID) {
            insertionIndex = index
        } else {
            insertionIndex = result.endIndex
        }
        result.insert(contentsOf: movedIDs, at: insertionIndex)
        return result
    }
}

enum BookmarkMenuExpansionPreferences {
    static let storageKey = "menuBarExpandedSections"

    static func expandedIDs(
        collections: [BookmarkCollection],
        defaults: UserDefaults = .standard
    ) -> Set<BookmarkMenuSectionID> {
        expandedIDs(
            collections: collections,
            rawValue: defaults.string(forKey: storageKey)
        )
    }

    static func expandedIDs(
        collections: [BookmarkCollection],
        rawValue: String?
    ) -> Set<BookmarkMenuSectionID> {
        if let rawValue {
            let validIDs = Set(BookmarkMenuSectionOrder.order(collections: collections))
            return Set(rawValue.split(separator: "\n").compactMap {
                BookmarkMenuSectionID(storageValue: String($0))
            }).intersection(validIDs)
        }

        var defaultsIDs: Set<BookmarkMenuSectionID> = [.recent]
        if let common = collections.first(where: { $0.name == "常用" }) {
            defaultsIDs.insert(.collection(common.id))
        }
        return defaultsIDs
    }

    static func encoded(_ ids: Set<BookmarkMenuSectionID>) -> String {
        ids.map(\.storageValue).sorted().joined(separator: "\n")
    }

    static func setExpanded(
        _ isExpanded: Bool,
        id: BookmarkMenuSectionID,
        collections: [BookmarkCollection],
        defaults: UserDefaults = .standard
    ) {
        var expanded = expandedIDs(collections: collections, defaults: defaults)
        if isExpanded {
            expanded.insert(id)
        } else {
            expanded.remove(id)
        }
        defaults.set(encoded(expanded), forKey: storageKey)
    }
}

struct BookmarkMenuSection: Equatable {
    var id: BookmarkMenuSectionID
    var title: String
    var bookmarks: [Bookmark]
}

struct BookmarkMenuRenderSection: Identifiable, Equatable {
    enum Presentation: Equatable {
        case inline
        case submenu
    }

    var id: BookmarkMenuSectionID
    var title: String
    var bookmarks: [Bookmark]
    var presentation: Presentation
}

struct BookmarkMenuSections: Equatable {
    var recent: [Bookmark]
    var collections: [BookmarkMenuSection]
    var ungrouped: [Bookmark]

    var isEmpty: Bool {
        recent.isEmpty && collections.allSatisfy(\.bookmarks.isEmpty) && ungrouped.isEmpty
    }

    func renderSections(expandedIDs: Set<BookmarkMenuSectionID>) -> [BookmarkMenuRenderSection] {
        let collectionSections = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        let order = BookmarkMenuSectionOrder.order(
            collections: collections.compactMap { section in
                guard case .collection(let id) = section.id else { return nil }
                return BookmarkCollection(id: id, name: section.title, sortOrder: 0)
            }
        )
        return order.compactMap { id in
            let title: String
            let bookmarks: [Bookmark]
            switch id {
            case .recent:
                title = "最近添加".obeliskLocalized
                bookmarks = recent
            case .collection:
                guard let section = collectionSections[id] else { return nil }
                title = section.title
                bookmarks = section.bookmarks
            case .ungrouped:
                title = "未分组".obeliskLocalized
                bookmarks = ungrouped
            }
            guard !bookmarks.isEmpty else { return nil }
            return BookmarkMenuRenderSection(
                id: id,
                title: "\(title) (\(bookmarks.count))",
                bookmarks: bookmarks,
                presentation: expandedIDs.contains(id) ? .inline : .submenu
            )
        }
    }
}
