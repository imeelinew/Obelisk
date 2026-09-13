import Foundation
import ObeliskCore

enum BookmarkListSortMode: String, CaseIterable, Identifiable {
    case recentlyAdded
    case recentlyUsed
    case mostFrequentlyUsed

    static let storageKey = "bookmarkCollectionListSortMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: "最近添加".obeliskLocalized
        case .recentlyUsed: "最近使用".obeliskLocalized
        case .mostFrequentlyUsed: "最常使用".obeliskLocalized
        }
    }
}
