import CryptoKit
import Foundation
import os

/// Thread-safe in-memory DEK cache populated by `VaultSession` after device authentication.
public enum VaultDataKeyCache {
    private static let state = OSAllocatedUnfairLock<SymmetricKey?>(initialState: nil)

    public static func install(_ key: SymmetricKey?) {
        state.withLock { $0 = key }
    }

    public static func current() throws -> SymmetricKey {
        guard let key = state.withLock({ $0 }) else {
            throw VaultSessionError.vaultLocked
        }
        return key
    }
}
