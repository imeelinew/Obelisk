import Foundation
import ObeliskCore

enum BookmarkListSortMode: String, CaseIterable, Identifiable {
    case recentlyAdded
    case frequency

    static let storageKey = "bookmarkCollectionListSortMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: "最近添加".obeliskLocalized
        case .frequency: "最近使用".obeliskLocalized
        }
    }
}
