import CryptoKit
import Foundation

#if DEBUG
public enum ObeliskTestVaultSupport {
    @discardableResult
    public static func installEphemeralKey() -> SymmetricKey {
        if let key = try? VaultDataKeyCache.current() {
            return key
        }
        let key = SymmetricKey(size: .bits256)
        VaultDataKeyCache.install(key)
        return key
    }

    public static func clearEphemeralKey() {
        VaultDataKeyCache.install(nil)
    }

    public static func encryptedBlobRawText(
        logicalName: String,
        rootDirectory: URL
    ) throws -> String {
        let key = try VaultDataKeyCache.current()
        let vault = VaultStorage(rootDirectory: rootDirectory)
        let manifest = try vault.loadManifest(key: key)
        guard let entry = manifest.entry(for: logicalName) else {
            throw VaultStorageError.missingEntry(logicalName)
        }
        let blobURL = VaultPaths.blobURL(in: rootDirectory, blobId: entry.blobId)
        let raw = try Data(contentsOf: blobURL)
        return String(decoding: raw, as: UTF8.self)
    }
}
#endif
