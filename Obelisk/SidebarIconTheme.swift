import Foundation

enum SidebarIconTheme: String, CaseIterable, Identifiable {
    case professional
    case colorful

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .colorful: return "多彩".obeliskLocalized
        case .professional: return "专业".obeliskLocalized
        }
    }
}

extension SidebarIconTheme {
    static let storageKey = "sidebarIconTheme"
}

enum SidebarIconStyle: String, CaseIterable, Identifiable {
    case tabler
    case lucide

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lucide: return "Lucid"
        case .tabler: return "Tabler"
        }
    }
}

extension SidebarIconStyle {
    static let storageKey = "sidebarIconStyle"
}
