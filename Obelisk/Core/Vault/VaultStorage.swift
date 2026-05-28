import CryptoKit
import Foundation

public enum VaultStorageError: LocalizedError {
    case vaultLocked
    case missingEntry(String)

    public var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return VaultSessionError.vaultLocked.errorDescription
        case .missingEntry(let name):
            return "Vault 中找不到条目：\(name)"
        }
    }
}

public final class VaultStorage {
    public static let manifestBlobId = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    private let rootDirectory: URL
    private let blobCodec = VaultBlobCodec()
    private var cachedManifest: VaultManifest?

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public static func usesVaultV2(in rootDirectory: URL) -> Bool {
        VaultPaths.isVaultV2Present(in: rootDirectory)
    }

    public func readLogical(_ logicalName: String, key: SymmetricKey) throws -> Data {
        let manifest = try loadManifest(key: key)
        guard let entry = manifest.entry(for: logicalName) else {
            throw VaultStorageError.missingEntry(logicalName)
        }
        let blobURL = VaultPaths.blobURL(in: rootDirectory, blobId: entry.blobId)
        let encrypted = try LocalFileAccess.readData(from: blobURL)
        return try blobCodec.open(
            encrypted,
            logicalName: logicalName,
            blobId: entry.blobId,
            using: key
        )
    }

    public func writeLogical(
        _ data: Data,
        logicalName: String,
        kind: VaultEntryKind,
        key: SymmetricKey
    ) throws {
        var manifest = (try? loadManifest(key: key)) ?? VaultManifest()
        let blobId: UUID
        if let existing = manifest.entry(for: logicalName) {
            blobId = existing.blobId
        } else {
            blobId = UUID()
        }

        let blobURL = VaultPaths.blobURL(in: rootDirectory, blobId: blobId)
        let encrypted = try blobCodec.seal(data, logicalName: logicalName, blobId: blobId, using: key)
        try ensureVaultDirectories()
        try LocalFileAccess.writeData(encrypted, to: blobURL)
        try VaultPaths.applyProtectedFileAttributes(at: blobURL)

        manifest.setEntry(
            VaultManifestEntry(blobId: blobId, kind: kind, updatedAt: Date()),
            for: logicalName
        )
        try saveManifest(manifest, key: key)
        cachedManifest = manifest
    }

    public func removeLogical(_ logicalName: String, key: SymmetricKey) throws {
        var manifest = try loadManifest(key: key)
        guard let entry = manifest.entry(for: logicalName) else { return }
        let blobURL = VaultPaths.blobURL(in: rootDirectory, blobId: entry.blobId)
        try? LocalFileAccess.removeItem(at: blobURL)
        manifest.removeEntry(for: logicalName)
        try saveManifest(manifest, key: key)
        cachedManifest = manifest
    }

    public func loadManifest(key: SymmetricKey) throws -> VaultManifest {
        if let cachedManifest {
            return cachedManifest
        }
        let manifestURL = VaultPaths.manifestURL(in: rootDirectory)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            let empty = VaultManifest()
            cachedManifest = empty
            return empty
        }
        let encrypted = try LocalFileAccess.readData(from: manifestURL)
        let data = try blobCodec.open(
            encrypted,
            logicalName: VaultPaths.manifestLogicalName,
            blobId: Self.manifestBlobId,
            using: key
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(VaultManifest.self, from: data)
        cachedManifest = manifest
        return manifest
    }

    public func saveManifest(_ manifest: VaultManifest, key: SymmetricKey) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let encrypted = try blobCodec.seal(
            data,
            logicalName: VaultPaths.manifestLogicalName,
            blobId: Self.manifestBlobId,
            using: key
        )
        try ensureVaultDirectories()
        let manifestURL = VaultPaths.manifestURL(in: rootDirectory)
        try LocalFileAccess.writeData(encrypted, to: manifestURL)
        try VaultPaths.applyProtectedFileAttributes(at: manifestURL)
        cachedManifest = manifest
    }

    public func invalidateCache() {
        cachedManifest = nil
    }

    private func ensureVaultDirectories() throws {
        let v2 = VaultPaths.v2Root(in: rootDirectory)
        let blobs = VaultPaths.blobsDirectory(in: rootDirectory)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try VaultPaths.applyVaultDirectoryAttributes(at: VaultPaths.vaultRoot(in: rootDirectory))
        try VaultPaths.applyVaultDirectoryAttributes(at: v2)
        try VaultPaths.applyVaultDirectoryAttributes(at: blobs)
    }
}
