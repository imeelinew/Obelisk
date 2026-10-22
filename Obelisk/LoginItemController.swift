import Foundation
import ServiceManagement
import ObeliskRuntime

@MainActor
enum LoginItemController {
    static var isEnabled: Bool {
        #if OBELISK_UI
        (try? UIRuntime.shared.client?.request(RuntimeRequest(.loginEnabled), as: Bool.self)) ?? false
        #else
        SMAppService.mainApp.status == .enabled
        #endif
    }

    static func setEnabled(_ isEnabled: Bool) async throws {
        #if OBELISK_UI
        var r = RuntimeRequest(.setLoginEnabled); r.flag = isEnabled
        let _: Bool? = try await UIRuntime.shared.client?.request(r)
        #else
        if isEnabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled else { return }
            try await SMAppService.mainApp.unregister()
        }
        #endif
    }
}
