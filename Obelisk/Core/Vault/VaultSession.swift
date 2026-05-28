import CryptoKit
import Foundation
import LocalAuthentication

public enum VaultSessionError: LocalizedError {
    case authenticationFailed
    case vaultLocked

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "未能通过本机认证，无法访问加密数据"
        case .vaultLocked:
            return "加密数据已锁定，请先解锁"
        }
    }
}

@MainActor
public final class VaultSession {
    public static let shared = VaultSession()

    private var authenticationContext: LAContext?
    private var cachedDEK: SymmetricKey?
    private var unlockedAt: Date?
    private let idleTimeout: TimeInterval = 30 * 60
    private let keyStore = VaultKeyStore()

    private init() {}

    public var isUnlocked: Bool {
        guard authenticationContext != nil, let unlockedAt else { return false }
        if Date().timeIntervalSince(unlockedAt) > idleTimeout {
            lock()
            return false
        }
        return true
    }

    public func lock() {
        authenticationContext?.invalidate()
        authenticationContext = nil
        cachedDEK = nil
        VaultDataKeyCache.install(nil)
        unlockedAt = nil
    }

    public func unlockIfNeeded(reason: String) async -> Bool {
        guard LocalJSONEncryption.isEnabled else { return true }
        if isUnlocked { return true }
        return await unlock(reason: reason)
    }

    @discardableResult
    public func unlock(reason: String) async -> Bool {
        guard LocalJSONEncryption.isEnabled else { return true }

        let context = LAContext()
        context.localizedReason = reason
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            guard success else { return false }
            authenticationContext = context
            let key = try keyStore.symmetricKey(authenticationContext: context)
            cachedDEK = key
            VaultDataKeyCache.install(key)
            unlockedAt = Date()
            return true
        } catch {
            return false
        }
    }

    public func dataKey() throws -> SymmetricKey {
        if !LocalJSONEncryption.isEnabled {
            throw VaultSessionError.vaultLocked
        }
        guard let cachedDEK, isUnlocked else {
            throw VaultSessionError.vaultLocked
        }
        return cachedDEK
    }

    public func authenticationContextForKeychain() throws -> LAContext {
        guard let authenticationContext, isUnlocked else {
            throw VaultSessionError.vaultLocked
        }
        return authenticationContext
    }

    public func requireUnlocked() throws {
        guard isUnlocked || !LocalJSONEncryption.isEnabled else {
            throw VaultSessionError.vaultLocked
        }
    }

    /// Creates the vault master key after authentication when no key exists yet.
    public func prepareNewVaultKey(rootDirectory: URL) throws -> SymmetricKey {
        let context = try authenticationContextForKeychain()
        let store = VaultKeyStore(encryptedPayloadsRoot: rootDirectory)
        return try store.getOrCreateKey(authenticationContext: context)
    }
}
