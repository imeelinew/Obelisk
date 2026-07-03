import Foundation

enum SidebarIconTheme: String, CaseIterable, Identifiable {
    case colorful
    case professional

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .colorful: return "多彩"
        case .professional: return "专业"
        }
    }
}

extension SidebarIconTheme {
    static let storageKey = "sidebarIconTheme"
}

enum SidebarIconStyle: String, CaseIterable, Identifiable {
    case lucide
    case tabler

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
