import Foundation
import ObeliskCore

enum BookmarkListSortMode: String, CaseIterable, Identifiable {
    case recentlyAdded
    case recentlyUsed
    case mostFrequentlyUsed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: "最近添加".obeliskLocalized
        case .recentlyUsed: "最近使用".obeliskLocalized
        case .mostFrequentlyUsed: "最常使用".obeliskLocalized
        }
    }
}

enum BookmarkListSortPreferences {
    static let storageKey = "bookmarkListSortModesBySection"

    static func mode(
        for sectionID: BookmarkMenuSectionID,
        rawValue: String?
    ) -> BookmarkListSortMode {
        decoded(rawValue)[sectionID.storageValue] ?? .recentlyAdded
    }

    static func setting(
        _ mode: BookmarkListSortMode,
        for sectionID: BookmarkMenuSectionID,
        in rawValue: String?
    ) -> String {
        var values = decoded(rawValue)
        if mode == .recentlyAdded {
            values.removeValue(forKey: sectionID.storageValue)
        } else {
            values[sectionID.storageValue] = mode
        }
        return encoded(values)
    }

    static func removing(
        _ sectionID: BookmarkMenuSectionID,
        from rawValue: String?
    ) -> String {
        var values = decoded(rawValue)
        values.removeValue(forKey: sectionID.storageValue)
        return encoded(values)
    }

    private static func decoded(_ rawValue: String?) -> [String: BookmarkListSortMode] {
        guard let rawValue else { return [:] }
        return rawValue.split(separator: "\n").reduce(into: [:]) { result, line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, let mode = BookmarkListSortMode(rawValue: String(fields[1])) else {
                return
            }
            result[String(fields[0])] = mode
        }
    }

    private static func encoded(_ values: [String: BookmarkListSortMode]) -> String {
        values.keys.sorted().compactMap { key in
            values[key].map { "\(key)\t\($0.rawValue)" }
        }.joined(separator: "\n")
    }
}
