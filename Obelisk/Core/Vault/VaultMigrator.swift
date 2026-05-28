import CryptoKit
import Foundation

public enum VaultMigrator {
    public static let logicalJSONFiles = ObeliskStorageMigrator.logicalJSONFiles

    /// Migrates legacy v1 encrypted/plain layouts into Vault v2. Idempotent when v2 already exists.
    public static func migrateToVaultV2IfNeeded(
        in rootDirectory: URL,
        key: SymmetricKey
    ) throws {
        guard LocalJSONEncryption.isEnabled else { return }
        guard !VaultStorage.usesVaultV2(in: rootDirectory) else { return }

        let legacyCodec = SecureJSONFileCodec()
        let vault = VaultStorage(rootDirectory: rootDirectory)

        for logicalName in logicalJSONFiles {
            guard let data = try? readBestLegacyData(
                logicalName: logicalName,
                rootDirectory: rootDirectory,
                codec: legacyCodec
            ) else {
                continue
            }
            try vault.writeLogical(data, logicalName: logicalName, kind: .json, key: key)
        }

        try migrateFavicons(
            rootDirectory: rootDirectory,
            legacyCodec: legacyCodec,
            vault: vault,
            key: key
        )

        try removeLegacyEncryptedArtifacts(in: rootDirectory)
    }

    /// Writes Vault v2 payloads back to plaintext `Data/` when encryption is disabled.
    public static func exportVaultV2ToPlaintext(in rootDirectory: URL, key: SymmetricKey) throws {
        guard VaultStorage.usesVaultV2(in: rootDirectory) else { return }

        let vault = VaultStorage(rootDirectory: rootDirectory)
        let dataDirectory = ObeliskPrivateStorage.dataDirectory(in: rootDirectory)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        for logicalName in logicalJSONFiles {
            guard let data = try? vault.readLogical(logicalName, key: key) else { continue }
            let destination = ObeliskPrivateStorage.legacyFileURL(
                rootDirectory: rootDirectory,
                logicalName: logicalName
            )
            try LocalFileAccess.writeData(data, to: destination)
        }

        let faviconDir = dataDirectory.appendingPathComponent("Favicons", isDirectory: true)
        try FileManager.default.createDirectory(at: faviconDir, withIntermediateDirectories: true)

        if let indexData = try? vault.readLogical(VaultPaths.faviconIndexLogicalName, key: key) {
            try LocalFileAccess.writeData(
                indexData,
                to: faviconDir.appendingPathComponent("index.json")
            )
        }

        let manifest = try vault.loadManifest(key: key)
        for (logicalName, entry) in manifest.entries where logicalName.hasPrefix("favicons/") && entry.kind == .binary {
            let data = try vault.readLogical(logicalName, key: key)
            let fileName = logicalName.replacingOccurrences(of: "favicons/", with: "")
            try LocalFileAccess.writeData(data, to: faviconDir.appendingPathComponent(fileName))
        }

        try LocalFileAccess.removeItem(at: VaultPaths.vaultRoot(in: rootDirectory))
    }

    private static func migrateFavicons(
        rootDirectory: URL,
        legacyCodec: SecureJSONFileCodec,
        vault: VaultStorage,
        key: SymmetricKey
    ) throws {
        let locations = faviconSourceLocations(in: rootDirectory)
        var mergedIndex: [String: FaviconRecord] = [:]

        for location in locations {
            let indexURL = ObeliskPrivateStorage.faviconIndexURL(
                directory: location.directory,
                encrypted: location.encrypted
            )
            guard let data = try? readFaviconBytes(from: indexURL, encrypted: location.encrypted, codec: legacyCodec),
                  let index = try? decodeFaviconIndex(data) else {
                continue
            }
            for (faviconKey, record) in index {
                if let existing = mergedIndex[faviconKey], existing.fetchedAt >= record.fetchedAt {
                    continue
                }
                mergedIndex[faviconKey] = record
            }
        }

        for (faviconKey, record) in mergedIndex where record.success {
            guard let data = newestFaviconData(
                for: faviconKey,
                in: locations,
                codec: legacyCodec
            ) else {
                continue
            }
            try vault.writeLogical(
                data,
                logicalName: VaultPaths.faviconIconLogicalName(key: faviconKey),
                kind: .binary,
                key: key
            )
        }

        if !mergedIndex.isEmpty {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let indexData = try encoder.encode(mergedIndex)
            try vault.writeLogical(
                indexData,
                logicalName: VaultPaths.faviconIndexLogicalName,
                kind: .json,
                key: key
            )
        }
    }

    private struct FaviconLocation {
        var directory: URL
        var encrypted: Bool
    }

    private struct FaviconRecord: Codable {
        var fetchedAt: Date
        var success: Bool
    }

    private static func faviconSourceLocations(in rootDirectory: URL) -> [FaviconLocation] {
        [
            FaviconLocation(
                directory: ObeliskPrivateStorage.faviconDirectory(in: rootDirectory, encrypted: false),
                encrypted: false
            ),
            FaviconLocation(
                directory: ObeliskPrivateStorage.faviconDirectory(in: rootDirectory, encrypted: true),
                encrypted: true
            ),
            FaviconLocation(
                directory: ObeliskPrivateStorage.legacyFaviconDirectory(in: rootDirectory),
                encrypted: false
            ),
            FaviconLocation(
                directory: ObeliskPrivateStorage.legacyEncryptedFaviconDirectory(in: rootDirectory),
                encrypted: true
            )
        ]
    }

    private static func decodeFaviconIndex(_ data: Data) throws -> [String: FaviconRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: FaviconRecord].self, from: data)
    }

    private static func readFaviconBytes(
        from url: URL,
        encrypted: Bool,
        codec: SecureJSONFileCodec
    ) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if encrypted {
            return try codec.readData(from: url)
        }
        return try LocalFileAccess.readData(from: url)
    }

    private static func newestFaviconData(
        for key: String,
        in locations: [FaviconLocation],
        codec: SecureJSONFileCodec
    ) -> Data? {
        locations
            .map {
                (
                    location: $0,
                    url: ObeliskPrivateStorage.faviconIconURL(
                        directory: $0.directory,
                        key: key,
                        encrypted: $0.encrypted
                    )
                )
            }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .sorted { lhs, rhs in
                modificationDate(for: lhs.url) > modificationDate(for: rhs.url)
            }
            .lazy
            .compactMap { pair -> Data? in
                try? readFaviconBytes(from: pair.url, encrypted: pair.location.encrypted, codec: codec)
            }
            .first
    }

    private static func readBestLegacyData(
        logicalName: String,
        rootDirectory: URL,
        codec: SecureJSONFileCodec
    ) throws -> Data {
        let candidates = [
            ObeliskPrivateStorage.fileURL(rootDirectory: rootDirectory, logicalName: logicalName, encrypted: true),
            ObeliskPrivateStorage.fileURL(rootDirectory: rootDirectory, logicalName: logicalName, encrypted: false),
            ObeliskPrivateStorage.legacyRootFileURL(rootDirectory: rootDirectory, logicalName: logicalName),
            ObeliskPrivateStorage.legacyPrivateFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
        ]
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        if logicalName == "bookmarks.json",
           let nonEmpty = try newestNonEmptyBookmarkData(from: existing, codec: codec) {
            return nonEmpty
        }
        var lastError: Error?
        for url in existing {
            do {
                return try codec.readData(from: url)
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func newestNonEmptyBookmarkData(
        from candidates: [URL],
        codec: SecureJSONFileCodec
    ) throws -> Data? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for candidate in candidates.sorted(by: { modificationDate(for: $0) > modificationDate(for: $1) }) {
            do {
                let data = try codec.readData(from: candidate)
                let database = try decoder.decode(BookmarkDatabase.self, from: data)
                if !database.bookmarks.isEmpty {
                    return data
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private static func modificationDate(for url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    private static func removeLegacyEncryptedArtifacts(in rootDirectory: URL) throws {
        let paths = [
            ObeliskPrivateStorage.encryptedDataDirectory(in: rootDirectory),
            ObeliskPrivateStorage.legacyEncryptedDataDirectory(in: rootDirectory),
            ObeliskPrivateStorage.legacyFaviconDirectory(in: rootDirectory)
        ]
        for path in paths {
            try? LocalFileAccess.removeItem(at: path)
        }
        let dataDir = ObeliskPrivateStorage.dataDirectory(in: rootDirectory)
        for logicalName in logicalJSONFiles {
            let plain = ObeliskPrivateStorage.legacyFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
            try? LocalFileAccess.removeItem(at: plain)
        }
        try? LocalFileAccess.removeItem(at: dataDir.appendingPathComponent("Favicons", isDirectory: true))
        ObeliskStorageMigrator.removeEmptyStorageDirectories(in: rootDirectory)
    }
}
