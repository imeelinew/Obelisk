import Foundation

/// Unified read/write for plaintext `Data/`, legacy v1 encrypted blobs, and Vault v2.
public enum ObeliskDataStorage {
    private static func legacyCodec() -> SecureJSONFileCodec {
        SecureJSONFileCodec()
    }

    public static func usesVaultV2(rootDirectory: URL) -> Bool {
        VaultStorage.usesVaultV2(in: rootDirectory)
    }

    public static func representativeURL(logicalName: String, rootDirectory: URL) -> URL {
        if LocalJSONEncryption.isEnabled, VaultStorage.usesVaultV2(in: rootDirectory) {
            return VaultPaths.manifestURL(in: rootDirectory)
        }
        return ObeliskPrivateStorage.activeFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
    }

    public static func existingReadableURL(logicalName: String, rootDirectory: URL) -> URL {
        if LocalJSONEncryption.isEnabled,
           VaultStorage.usesVaultV2(in: rootDirectory),
           let key = try? VaultDataKeyCache.current(),
           let vault = try? VaultStorage(rootDirectory: rootDirectory).loadManifest(key: key),
           vault.entry(for: logicalName) != nil {
            return VaultPaths.manifestURL(in: rootDirectory)
        }
        return ObeliskPrivateStorage.existingReadableFileURL(
            rootDirectory: rootDirectory,
            logicalName: logicalName
        )
    }

    public static func readLogical(_ logicalName: String, rootDirectory: URL) throws -> Data {
        if LocalJSONEncryption.isEnabled, VaultStorage.usesVaultV2(in: rootDirectory) {
            let key = try VaultDataKeyCache.current()
            return try VaultStorage(rootDirectory: rootDirectory).readLogical(logicalName, key: key)
        }
        let url = ObeliskPrivateStorage.existingReadableFileURL(
            rootDirectory: rootDirectory,
            logicalName: logicalName
        )
        return try readData(from: url)
    }

    public static func writeLogical(
        _ data: Data,
        logicalName: String,
        rootDirectory: URL,
        encrypted: Bool,
        kind: VaultEntryKind = .json
    ) throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        if encrypted, VaultStorage.usesVaultV2(in: rootDirectory) || shouldWriteVaultV2(rootDirectory: rootDirectory, encrypted: encrypted) {
            let key = try VaultDataKeyCache.current()
            let vaultURL = VaultPaths.manifestURL(in: rootDirectory)
            try VaultStorage(rootDirectory: rootDirectory).writeLogical(
                data,
                logicalName: logicalName,
                kind: kind,
                key: key
            )
            try removeInactiveCopies(
                logicalName: logicalName,
                rootDirectory: rootDirectory,
                keeping: vaultURL
            )
            return
        }

        let url = ObeliskPrivateStorage.fileURL(
            rootDirectory: rootDirectory,
            logicalName: logicalName,
            encrypted: encrypted
        )
        try writeData(data, to: url, encrypted: encrypted)
        try removeInactiveCopies(logicalName: logicalName, rootDirectory: rootDirectory, keeping: url)
    }

    private static func removeInactiveCopies(
        logicalName: String,
        rootDirectory: URL,
        keeping activeURL: URL
    ) throws {
        let activePath = activeURL.standardizedFileURL.path
        for stale in ObeliskPrivateStorage.inactiveFileURLs(
            rootDirectory: rootDirectory,
            logicalName: logicalName
        ) where stale.standardizedFileURL.path != activePath {
            try? LocalFileAccess.removeItem(at: stale)
        }
        let legacyRoot = ObeliskPrivateStorage.legacyRootFileURL(
            rootDirectory: rootDirectory,
            logicalName: logicalName
        )
        if legacyRoot.standardizedFileURL.path != activePath {
            try? LocalFileAccess.removeItem(at: legacyRoot)
        }
    }

    public static func readData(from url: URL) throws -> Data {
        try legacyCodec().readData(from: url)
    }

    public static func writeData(_ data: Data, to url: URL, encrypted: Bool) throws {
        try legacyCodec().writeData(data, to: url, encrypted: encrypted)
    }

    private static func shouldWriteVaultV2(rootDirectory: URL, encrypted: Bool) -> Bool {
        encrypted && LocalJSONEncryption.isEnabled
    }
}
