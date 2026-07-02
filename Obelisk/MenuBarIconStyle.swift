import Foundation

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case outline
    case filled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .outline: return "空心"
        case .filled: return "实心"
        }
    }
}

extension MenuBarIconStyle {
    static let storageKey = "menuBarIconStyle"
}
