import Foundation

/// Exports a point-in-time plaintext snapshot outside the private vault.
public enum ObeliskPlaintextDataBackup {
    public struct Result: Sendable {
        public let destinationURL: URL
        public let exportedJSONFiles: [String]
        public let exportedFaviconCount: Int
    }

    public enum BackupError: LocalizedError {
        case destinationAlreadyExists(URL)
        case nothingToExport

        public var errorDescription: String? {
            switch self {
            case .destinationAlreadyExists(let url):
                return "备份目录已存在：\(url.lastPathComponent)"
            case .nothingToExport:
                return "没有可备份的数据文件"
            }
        }
    }

    private static let jsonLogicalNames = ObeliskStorageMigrator.logicalJSONFiles
    private static let payloadBackupFileName = "payload.json"
    private static let backupFolderPrefix = "Backup-"

    public static func createBackup(
        in rootDirectory: URL,
        destinationParent: URL,
        now: Date = Date()
    ) throws -> Result {
        let fileManager = FileManager.default
        let destinationRoot = destinationParent
            .appendingPathComponent(backupFolderName(for: now), isDirectory: true)
        guard !fileManager.fileExists(atPath: destinationRoot.path) else {
            throw BackupError.destinationAlreadyExists(destinationRoot)
        }

        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let codec = SecureJSONFileCodec()
        var exportedJSONFiles: [String] = []

        if let payloadData = try readVaultPayloadJSON(from: rootDirectory) {
            try LocalFileAccess.writeData(
                payloadData,
                to: destinationRoot.appendingPathComponent(payloadBackupFileName)
            )
            exportedJSONFiles.append(payloadBackupFileName)
        } else {
            for logicalName in jsonLogicalNames {
                guard let plaintext = try readPlaintextJSON(
                    logicalName: logicalName,
                    from: rootDirectory,
                    codec: codec
                ) else {
                    continue
                }
                let destinationURL = destinationRoot.appendingPathComponent(logicalName)
                try LocalFileAccess.writeData(plaintext, to: destinationURL)
                exportedJSONFiles.append(logicalName)
            }
        }

        let faviconCount = try exportFavicons(
            from: rootDirectory,
            to: destinationRoot.appendingPathComponent("Favicons", isDirectory: true),
            codec: codec
        )

        guard !exportedJSONFiles.isEmpty || faviconCount > 0 else {
            try? fileManager.removeItem(at: destinationRoot)
            throw BackupError.nothingToExport
        }

        return Result(
            destinationURL: destinationRoot,
            exportedJSONFiles: exportedJSONFiles,
            exportedFaviconCount: faviconCount
        )
    }

    private static func backupFolderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return backupFolderPrefix + formatter.string(from: date)
    }

    private static func readPlaintextJSON(
        logicalName: String,
        from rootDirectory: URL,
        codec: SecureJSONFileCodec
    ) throws -> Data? {
        let candidates = candidateJSONURLs(rootDirectory: rootDirectory, logicalName: logicalName)
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }

        if logicalName == "bookmarks.json",
           let data = try newestNonEmptyBookmarkData(from: existing, codec: codec) {
            return data
        }

        var lastError: Error?
        for url in existing {
            do {
                return try codec.readData(from: url)
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        return nil
    }

    private static func readVaultPayloadJSON(from rootDirectory: URL) throws -> Data? {
        let vaultStore = ObeliskVaultStore(rootDirectory: rootDirectory)
        guard vaultStore.hasV2Payload else {
            return nil
        }
        let payload = try vaultStore.loadPayload()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private static func candidateJSONURLs(rootDirectory: URL, logicalName: String) -> [URL] {
        [
            ObeliskPrivateStorage.activeFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
        ].sorted { modificationDate(for: $0) > modificationDate(for: $1) }
    }

    private static func newestNonEmptyBookmarkData(
        from candidates: [URL],
        codec: SecureJSONFileCodec
    ) throws -> Data? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for candidate in candidates {
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
        for candidate in candidates {
            do {
                return try codec.readData(from: candidate)
            } catch {
                continue
            }
        }
        return nil
    }

    private static func exportFavicons(
        from rootDirectory: URL,
        to faviconDirectory: URL,
        codec: SecureJSONFileCodec
    ) throws -> Int {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: faviconDirectory, withIntermediateDirectories: true)

        var mergedIndex: [String: FaviconRecord] = [:]
        for location in faviconSourceLocations(in: rootDirectory) {
            let index = loadFaviconIndex(in: location, rootDirectory: rootDirectory, codec: codec)
            for (key, record) in index {
                if let existing = mergedIndex[key], existing.fetchedAt >= record.fetchedAt {
                    continue
                }
                mergedIndex[key] = record
            }
        }

        var exportedCount = 0
        for (key, record) in mergedIndex where record.success {
            guard let data = newestReadableFaviconData(
                for: key,
                in: faviconSourceLocations(in: rootDirectory),
                rootDirectory: rootDirectory,
                codec: codec
            ) else {
                continue
            }
            let destinationURL = faviconDirectory.appendingPathComponent("\(key).png")
            try LocalFileAccess.writeData(data, to: destinationURL)
            exportedCount += 1
        }

        if !mergedIndex.isEmpty {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let indexData = try encoder.encode(mergedIndex)
            try LocalFileAccess.writeData(
                indexData,
                to: faviconDirectory.appendingPathComponent("index.json")
            )
        }

        return exportedCount
    }

    private struct FaviconRecord: Codable {
        var fetchedAt: Date
        var success: Bool
    }

    private struct FaviconLocation {
        var directory: URL
        var encrypted: Bool
    }

    private static func faviconSourceLocations(in rootDirectory: URL) -> [FaviconLocation] {
        uniqueFaviconLocations([
            FaviconLocation(
                directory: ObeliskPrivateStorage.faviconDirectory(in: rootDirectory),
                encrypted: LocalJSONEncryption.isEnabled
            )
        ])
    }

    private static func uniqueFaviconLocations(_ locations: [FaviconLocation]) -> [FaviconLocation] {
        var seen = Set<String>()
        return locations.filter { seen.insert($0.directory.standardizedFileURL.path).inserted }
    }

    private static func loadFaviconIndex(
        in location: FaviconLocation,
        rootDirectory: URL,
        codec: SecureJSONFileCodec
    ) -> [String: FaviconRecord] {
        let indexURL = ObeliskPrivateStorage.faviconIndexURL(
            directory: location.directory,
            encrypted: location.encrypted
        )
        guard let data = try? readFaviconData(from: indexURL, encrypted: location.encrypted, codec: codec) else {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: FaviconRecord].self, from: data)) ?? [:]
    }

    private static func newestReadableFaviconData(
        for key: String,
        in locations: [FaviconLocation],
        rootDirectory: URL,
        codec: SecureJSONFileCodec
    ) -> Data? {
        locations
            .map { location in
                (
                    location: location,
                    url: ObeliskPrivateStorage.faviconIconURL(
                        directory: location.directory,
                        key: key,
                        encrypted: location.encrypted
                    )
                )
            }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .sorted { modificationDate(for: $0.url) > modificationDate(for: $1.url) }
            .lazy
            .compactMap { try? readFaviconData(from: $0.url, encrypted: $0.location.encrypted, codec: codec) }
            .first
    }

    private static func readFaviconData(
        from url: URL,
        encrypted: Bool,
        codec: SecureJSONFileCodec
    ) throws -> Data {
        if encrypted || codec.isEncryptedFile(at: url) {
            return try codec.readData(from: url)
        }
        return try LocalFileAccess.readData(from: url)
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func modificationDate(for url: URL) -> Date {
        (
            try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        ) ?? .distantPast
    }
}

public enum ObeliskStorageTransition {
    @discardableResult
    public static func backUpThenNormalize(
        in rootDirectory: URL,
        encrypted: Bool,
        backup: (URL) throws -> ObeliskPlaintextDataBackup.Result? = { rootDirectory in
            do {
                return try ObeliskPlaintextDataBackup.createBackup(
                    in: rootDirectory,
                    destinationParent: rootDirectory.deletingLastPathComponent()
                )
            } catch ObeliskPlaintextDataBackup.BackupError.nothingToExport {
                return nil
            }
        }
    ) throws -> ObeliskPlaintextDataBackup.Result? {
        let result = try backup(rootDirectory)
        try ObeliskStorageMigrator.normalizeStorage(in: rootDirectory, encrypted: encrypted)
        return result
    }
}
