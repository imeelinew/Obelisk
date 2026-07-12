import AppKit
import Foundation

enum PermissionSettingsDestination: Equatable {
    case accessibility
    case automation
    case fullDiskAccess

    fileprivate var url: URL? {
        switch self {
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .automation:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .fullDiskAccess:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        }
    }
}

enum PermissionSettingsGuide {
    static func open(_ destination: PermissionSettingsDestination) {
        guard let url = destination.url else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }
}
