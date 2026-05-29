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
