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
    static func order(collections: [BookmarkCollection]) -> [BookmarkMenuSectionID] {
        [.recent] + collections.map { .collection($0.id) } + [.ungrouped]
    }

    static func items(collections: [BookmarkCollection]) -> [BookmarkMenuOrderItem] {
        [
            BookmarkMenuOrderItem(
                id: .recent,
                title: "最近添加".obeliskLocalized,
                systemImage: "clock.arrow.circlepath"
            )
        ] + collections.map {
            BookmarkMenuOrderItem(
                id: .collection($0.id),
                title: $0.name,
                systemImage: "folder.fill"
            )
        } + [
            BookmarkMenuOrderItem(
                id: .ungrouped,
                title: "未分组".obeliskLocalized,
                systemImage: "bookmark.fill"
            )
        ]
    }
}

enum BookmarkMenuExpansionPreferences {
    static let storageKey = "menuBarExpandedSections"

    static func expandedIDs(
        collections: [BookmarkCollection],
        defaults: UserDefaults = .standard
    ) -> Set<BookmarkMenuSectionID> {
        if let raw = defaults.string(forKey: storageKey) {
            let validIDs = Set(BookmarkMenuSectionOrder.order(collections: collections))
            return Set(raw.split(separator: "\n").compactMap {
                BookmarkMenuSectionID(storageValue: String($0))
            }).intersection(validIDs)
        }

        var defaultsIDs: Set<BookmarkMenuSectionID> = [.recent]
        if let common = collections.first(where: { $0.name == "常用" }) {
            defaultsIDs.insert(.collection(common.id))
        }
        return defaultsIDs
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
        defaults.set(
            expanded.map(\.storageValue).sorted().joined(separator: "\n"),
            forKey: storageKey
        )
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
        let order = [.recent] + collections.map(\.id) + [.ungrouped]
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
