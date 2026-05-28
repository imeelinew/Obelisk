import Foundation
import Security

enum ObeliskKeychain {
    static let accessGroupSuffix = "com.eli.Obelisk"

    static var accessGroup: String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let groups = SecTaskCopyValueForEntitlement(
            task,
            "keychain-access-groups" as CFString,
            nil
        ) as? [String] else {
            return nil
        }
        return groups.first { !$0.isEmpty }
    }

    static func applyAccessGroup(to query: inout [String: Any]) {
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
    }
}
