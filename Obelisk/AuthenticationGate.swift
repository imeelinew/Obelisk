import Foundation
import LocalAuthentication
import ObeliskRuntime

enum AuthenticationGate {
    @MainActor static func authenticate(reason: String) async -> Bool {
        #if OBELISK_UI
        var r = RuntimeRequest(.authenticate); r.title = reason
        return (try? await UIRuntime.shared.client?.request(r, as: Bool.self)) ?? false
        #else
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else {
            return false
        }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }

        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: trimmedReason)
        } catch {
            return false
        }
        #endif
    }
}
