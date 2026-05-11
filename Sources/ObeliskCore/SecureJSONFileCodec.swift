import CryptoKit
import Foundation
import Security

public enum LocalJSONEncryption {
    public static let enabledKey = "encryptLocalJSONData"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

public enum ICloudDocumentSyncError: LocalizedError {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "iCloud Drive 不可用。请确认已登录 Apple 账户并开启 iCloud Drive。"
        }
    }
}

public enum ICloudDocumentSync {
    public static let enabledKey = "syncWithICloudDrive"
    public static let cachedRootPathKey = "iCloudDocumentSyncRootPath"
    public static let containerIdentifier = "iCloud.local.elidev.Obelisk"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    public static func cachedRootDirectory() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: cachedRootPathKey), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func setCachedRootDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: cachedRootPathKey)
    }

    public static func shouldCoordinateAccess(for rootDirectory: URL) -> Bool {
        if isEnabled {
            return true
        }
        return cachedRootDirectory()?.standardizedFileURL == rootDirectory.standardizedFileURL
    }

    public static func resolveRootDirectory() async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let rootURL: URL
            if let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
                rootURL = containerURL
                    .appendingPathComponent("Documents", isDirectory: true)
                    .appendingPathComponent("Obelisk", isDirectory: true)
            } else if let cloudDocumentsURL = cloudDocumentsFallbackURL() {
                rootURL = cloudDocumentsURL.appendingPathComponent("Obelisk", isDirectory: true)
            } else {
                throw ICloudDocumentSyncError.unavailable
            }

            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            return rootURL
        }.value
    }

    private static func cloudDocumentsFallbackURL() -> URL? {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }
}

public enum ObeliskPrivateStorage {
    public static let dataDirectoryName = "Data"
    public static let encryptedDataDirectoryName = "EncryptedData"
    public static let legacyEncryptedDataDirectoryName = "PrivateData"

    public static func dataDirectory(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(dataDirectoryName, isDirectory: true)
    }

    public static func encryptedDataDirectory(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(encryptedDataDirectoryName, isDirectory: true)
    }

    public static func legacyEncryptedDataDirectory(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(legacyEncryptedDataDirectoryName, isDirectory: true)
    }

    public static func faviconDirectory(in rootDirectory: URL) -> URL {
        faviconDirectory(in: rootDirectory, encrypted: LocalJSONEncryption.isEnabled)
    }

    public static func faviconDirectory(in rootDirectory: URL, encrypted: Bool) -> URL {
        (encrypted ? encryptedDataDirectory(in: rootDirectory) : dataDirectory(in: rootDirectory))
            .appendingPathComponent("Favicons", isDirectory: true)
    }

    public static func legacyFaviconDirectory(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("favicons", isDirectory: true)
    }

    public static func legacyEncryptedFaviconDirectory(in rootDirectory: URL) -> URL {
        legacyEncryptedDataDirectory(in: rootDirectory).appendingPathComponent("Favicons", isDirectory: true)
    }

    public static func faviconIndexURL(rootDirectory: URL, encrypted: Bool) -> URL {
        faviconIndexURL(directory: faviconDirectory(in: rootDirectory, encrypted: encrypted), encrypted: encrypted)
    }

    public static func faviconIconURL(rootDirectory: URL, key: String, encrypted: Bool) -> URL {
        faviconIconURL(directory: faviconDirectory(in: rootDirectory, encrypted: encrypted), key: key, encrypted: encrypted)
    }

    public static func legacyFaviconIndexURL(rootDirectory: URL, encrypted: Bool) -> URL {
        let directory = encrypted
            ? legacyEncryptedFaviconDirectory(in: rootDirectory)
            : legacyFaviconDirectory(in: rootDirectory)
        return faviconIndexURL(directory: directory, encrypted: encrypted)
    }

    public static func legacyFaviconIconURL(rootDirectory: URL, key: String, encrypted: Bool) -> URL {
        let directory = encrypted
            ? legacyEncryptedFaviconDirectory(in: rootDirectory)
            : legacyFaviconDirectory(in: rootDirectory)
        return faviconIconURL(directory: directory, key: key, encrypted: encrypted)
    }

    public static func faviconIndexURL(directory: URL, encrypted: Bool) -> URL {
        encrypted
            ? directory.appendingPathComponent("\(obscuredName(for: "favicons/index.json")).bin")
            : directory.appendingPathComponent("index.json")
    }

    public static func faviconIconURL(directory: URL, key: String, encrypted: Bool) -> URL {
        encrypted
            ? directory.appendingPathComponent("\(obscuredName(for: "favicons/\(key).png")).bin")
            : directory.appendingPathComponent("\(key).png")
    }

    public static func legacyFileURL(rootDirectory: URL, logicalName: String) -> URL {
        dataDirectory(in: rootDirectory).appendingPathComponent(logicalName)
    }

    public static func privateFileURL(rootDirectory: URL, logicalName: String) -> URL {
        encryptedDataDirectory(in: rootDirectory).appendingPathComponent("\(obscuredName(for: logicalName)).bin")
    }

    public static func legacyRootFileURL(rootDirectory: URL, logicalName: String) -> URL {
        rootDirectory.appendingPathComponent(logicalName)
    }

    public static func legacyPrivateFileURL(rootDirectory: URL, logicalName: String) -> URL {
        legacyEncryptedDataDirectory(in: rootDirectory).appendingPathComponent("\(obscuredName(for: logicalName)).bin")
    }

    public static func fileURL(rootDirectory: URL, logicalName: String, encrypted: Bool) -> URL {
        encrypted
            ? privateFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
            : legacyFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
    }

    public static func activeFileURL(rootDirectory: URL, logicalName: String) -> URL {
        LocalJSONEncryption.isEnabled
            ? privateFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
            : legacyFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
    }

    public static func inactiveFileURL(rootDirectory: URL, logicalName: String) -> URL {
        fileURL(
            rootDirectory: rootDirectory,
            logicalName: logicalName,
            encrypted: !LocalJSONEncryption.isEnabled
        )
    }

    public static func inactiveFileURLs(rootDirectory: URL, logicalName: String) -> [URL] {
        let activeURL = activeFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
        return uniqueURLs([
            inactiveFileURL(rootDirectory: rootDirectory, logicalName: logicalName),
            legacyRootFileURL(rootDirectory: rootDirectory, logicalName: logicalName),
            legacyPrivateFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
        ]).filter { $0.standardizedFileURL != activeURL.standardizedFileURL }
    }

    public static func existingReadableFileURL(rootDirectory: URL, logicalName: String) -> URL {
        let activeURL = activeFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
        let candidates = [
            activeURL,
            inactiveFileURL(rootDirectory: rootDirectory, logicalName: logicalName),
            legacyRootFileURL(rootDirectory: rootDirectory, logicalName: logicalName),
            legacyPrivateFileURL(rootDirectory: rootDirectory, logicalName: logicalName)
        ]

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? activeURL
    }

    public static func obscuredName(for logicalName: String) -> String {
        let material = "local.elidev.Obelisk.private-storage.v1:\(logicalName)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

public enum ObeliskStorageMigrator {
    private struct FaviconRecord: Codable {
        var fetchedAt: Date
        var success: Bool
    }

    private struct FaviconLocation {
        var directory: URL
        var encrypted: Bool
    }

    public static let logicalJSONFiles = [
        "llm.json",
        "bookmarks.json",
        "bookmark_state.json",
        "usage.json"
    ]

    public static func normalizeStorage(in rootDirectory: URL, encrypted: Bool) throws {
        try normalizeJSONFiles(in: rootDirectory, encrypted: encrypted)
        try normalizeFavicons(in: rootDirectory, encrypted: encrypted)
        removeEmptyStorageDirectories(in: rootDirectory)
    }

    public static func normalizeJSONFiles(
        in rootDirectory: URL,
        encrypted: Bool,
        logicalNames: [String] = logicalJSONFiles
    ) throws {
        defer { removeEmptyStorageDirectories(in: rootDirectory) }

        let codec = SecureJSONFileCodec()
        let fileManager = FileManager.default

        for logicalName in logicalNames {
            let targetURL = ObeliskPrivateStorage.fileURL(
                rootDirectory: rootDirectory,
                logicalName: logicalName,
                encrypted: encrypted
            )
            let candidateURLs = uniqueURLs([
                targetURL,
                ObeliskPrivateStorage.fileURL(
                    rootDirectory: rootDirectory,
                    logicalName: logicalName,
                    encrypted: !encrypted
                ),
                ObeliskPrivateStorage.legacyRootFileURL(
                    rootDirectory: rootDirectory,
                    logicalName: logicalName
                ),
                ObeliskPrivateStorage.legacyPrivateFileURL(
                    rootDirectory: rootDirectory,
                    logicalName: logicalName
                )
            ])

            let existingCandidates = candidateURLs
                .filter { fileManager.fileExists(atPath: $0.path) }
                .sorted { lhs, rhs in
                    modificationDate(for: lhs) > modificationDate(for: rhs)
                }
            guard !existingCandidates.isEmpty else {
                continue
            }

            let plaintext = try readNewestAvailableData(
                from: existingCandidates,
                codec: codec,
                coordinated: shouldCoordinate(rootDirectory)
            )
            try fileManager.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try codec.writeData(
                plaintext,
                to: targetURL,
                encrypted: encrypted,
                coordinated: shouldCoordinate(rootDirectory)
            )

            for staleURL in candidateURLs where staleURL.standardizedFileURL != targetURL.standardizedFileURL {
                try? CoordinatedFileAccess.removeItem(
                    at: staleURL,
                    coordinated: shouldCoordinate(rootDirectory)
                )
            }
        }
    }

    public static func normalizeFavicons(in rootDirectory: URL, encrypted: Bool) throws {
        defer { removeEmptyStorageDirectories(in: rootDirectory) }

        let targetLocation = FaviconLocation(
            directory: ObeliskPrivateStorage.faviconDirectory(in: rootDirectory, encrypted: encrypted),
            encrypted: encrypted
        )
        let sourceLocations = faviconLocations(in: rootDirectory)
            .filter { FileManager.default.fileExists(atPath: $0.directory.path) }

        var mergedIndex = loadFaviconIndex(in: targetLocation, rootDirectory: rootDirectory)
        for location in sourceLocations {
            let sourceIndex = loadFaviconIndex(in: location, rootDirectory: rootDirectory)
            for (key, record) in sourceIndex {
                if let existing = mergedIndex[key], existing.fetchedAt >= record.fetchedAt {
                    continue
                }
                mergedIndex[key] = record
            }
        }

        for (key, record) in mergedIndex where record.success {
            guard let data = newestReadableFaviconData(
                for: key,
                in: sourceLocations,
                rootDirectory: rootDirectory
            ) else {
                continue
            }
            let destinationURL = ObeliskPrivateStorage.faviconIconURL(
                directory: targetLocation.directory,
                key: key,
                encrypted: targetLocation.encrypted
            )
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeFaviconData(data, to: destinationURL, encrypted: targetLocation.encrypted, rootDirectory: rootDirectory)
        }

        if !mergedIndex.isEmpty || !sourceLocations.isEmpty {
            try saveFaviconIndex(mergedIndex, in: targetLocation, rootDirectory: rootDirectory)
        }

        for location in sourceLocations
            where location.directory.standardizedFileURL != targetLocation.directory.standardizedFileURL {
            try? CoordinatedFileAccess.removeItem(
                at: location.directory,
                coordinated: shouldCoordinate(rootDirectory)
            )
        }
    }

    public static func migrateFavicons(from sourceRoot: URL, to targetRoot: URL, encrypted: Bool) throws {
        try normalizeFavicons(in: sourceRoot, encrypted: encrypted)
        try normalizeFavicons(in: targetRoot, encrypted: encrypted)

        let sourceLocation = FaviconLocation(
            directory: ObeliskPrivateStorage.faviconDirectory(in: sourceRoot, encrypted: encrypted),
            encrypted: encrypted
        )
        let targetLocation = FaviconLocation(
            directory: ObeliskPrivateStorage.faviconDirectory(in: targetRoot, encrypted: encrypted),
            encrypted: encrypted
        )
        let sourceIndex = loadFaviconIndex(in: sourceLocation, rootDirectory: sourceRoot)
        var targetIndex = loadFaviconIndex(in: targetLocation, rootDirectory: targetRoot)

        for (key, record) in sourceIndex {
            let sourceURL = ObeliskPrivateStorage.faviconIconURL(
                directory: sourceLocation.directory,
                key: key,
                encrypted: sourceLocation.encrypted
            )
            if record.success,
               let data = try? readFaviconData(from: sourceURL, encrypted: sourceLocation.encrypted, rootDirectory: sourceRoot) {
                let destinationURL = ObeliskPrivateStorage.faviconIconURL(
                    directory: targetLocation.directory,
                    key: key,
                    encrypted: targetLocation.encrypted
                )
                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try writeFaviconData(data, to: destinationURL, encrypted: targetLocation.encrypted, rootDirectory: targetRoot)
            }

            if let existing = targetIndex[key], existing.fetchedAt >= record.fetchedAt {
                continue
            }
            targetIndex[key] = record
        }

        if !targetIndex.isEmpty {
            try saveFaviconIndex(targetIndex, in: targetLocation, rootDirectory: targetRoot)
        }
        removeEmptyStorageDirectories(in: sourceRoot)
        removeEmptyStorageDirectories(in: targetRoot)
    }

    public static func removeEmptyStorageDirectories(in rootDirectory: URL) {
        let coordinated = shouldCoordinate(rootDirectory)
        let directories = [
            ObeliskPrivateStorage.faviconDirectory(in: rootDirectory, encrypted: false),
            ObeliskPrivateStorage.faviconDirectory(in: rootDirectory, encrypted: true),
            ObeliskPrivateStorage.legacyEncryptedFaviconDirectory(in: rootDirectory),
            ObeliskPrivateStorage.legacyFaviconDirectory(in: rootDirectory),
            ObeliskPrivateStorage.dataDirectory(in: rootDirectory),
            ObeliskPrivateStorage.encryptedDataDirectory(in: rootDirectory),
            ObeliskPrivateStorage.legacyEncryptedDataDirectory(in: rootDirectory)
        ]

        for directory in directories {
            removeIfEmpty(directory, coordinated: coordinated)
        }
    }

    private static func removeIfEmpty(_ directory: URL, coordinated: Bool) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ),
              contents.isEmpty
        else {
            return
        }
        try? CoordinatedFileAccess.removeItem(at: directory, coordinated: coordinated)
    }

    private static func faviconLocations(in rootDirectory: URL) -> [FaviconLocation] {
        uniqueFaviconLocations([
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
        ])
    }

    private static func uniqueFaviconLocations(_ locations: [FaviconLocation]) -> [FaviconLocation] {
        var seen = Set<String>()
        return locations.filter { seen.insert($0.directory.standardizedFileURL.path).inserted }
    }

    private static func loadFaviconIndex(
        in location: FaviconLocation,
        rootDirectory: URL
    ) -> [String: FaviconRecord] {
        let indexURL = ObeliskPrivateStorage.faviconIndexURL(
            directory: location.directory,
            encrypted: location.encrypted
        )
        guard let data = try? readFaviconData(
            from: indexURL,
            encrypted: location.encrypted,
            rootDirectory: rootDirectory
        ) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: FaviconRecord].self, from: data)) ?? [:]
    }

    private static func saveFaviconIndex(
        _ index: [String: FaviconRecord],
        in location: FaviconLocation,
        rootDirectory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: location.directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(index)
        let indexURL = ObeliskPrivateStorage.faviconIndexURL(
            directory: location.directory,
            encrypted: location.encrypted
        )
        try writeFaviconData(data, to: indexURL, encrypted: location.encrypted, rootDirectory: rootDirectory)
    }

    private static func newestReadableFaviconData(
        for key: String,
        in locations: [FaviconLocation],
        rootDirectory: URL
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
            .sorted { lhs, rhs in
                modificationDate(for: lhs.url) > modificationDate(for: rhs.url)
            }
            .lazy
            .compactMap {
                try? readFaviconData(
                    from: $0.url,
                    encrypted: $0.location.encrypted,
                    rootDirectory: rootDirectory
                )
            }
            .first
    }

    private static func readFaviconData(from url: URL, encrypted: Bool, rootDirectory: URL) throws -> Data {
        if encrypted {
            return try SecureJSONFileCodec().readData(
                from: url,
                coordinated: shouldCoordinate(rootDirectory)
            )
        }
        return try CoordinatedFileAccess.readData(from: url, coordinated: shouldCoordinate(rootDirectory))
    }

    private static func writeFaviconData(_ data: Data, to url: URL, encrypted: Bool, rootDirectory: URL) throws {
        if encrypted {
            try SecureJSONFileCodec().writeData(
                data,
                to: url,
                encrypted: true,
                coordinated: shouldCoordinate(rootDirectory)
            )
        } else {
            try CoordinatedFileAccess.writeData(
                data,
                to: url,
                coordinated: shouldCoordinate(rootDirectory)
            )
        }
    }

    private static func shouldCoordinate(_ rootDirectory: URL) -> Bool {
        ICloudDocumentSync.shouldCoordinateAccess(for: rootDirectory)
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

    private static func readNewestAvailableData(
        from candidates: [URL],
        codec: SecureJSONFileCodec,
        coordinated: Bool
    ) throws -> Data {
        var lastError: Error?
        for candidate in candidates {
            do {
                return try codec.readData(from: candidate, coordinated: coordinated)
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

public enum CoordinatedFileAccess {
    public static func readData(from url: URL) throws -> Data {
        try readData(from: url, coordinated: ICloudDocumentSync.isEnabled)
    }

    public static func readData(from url: URL, coordinated: Bool) throws -> Data {
        guard coordinated else {
            return try Data(contentsOf: url)
        }

        var result: Result<Data, Error>?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordinatedURL in
            result = Result {
                try Data(contentsOf: coordinatedURL)
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        return try result?.get() ?? Data(contentsOf: url)
    }

    public static func writeData(_ data: Data, to url: URL, options: Data.WritingOptions = [.atomic]) throws {
        try writeData(data, to: url, options: options, coordinated: ICloudDocumentSync.isEnabled)
    }

    public static func writeData(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions = [.atomic],
        coordinated: Bool
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard coordinated else {
            try data.write(to: url, options: options)
            return
        }

        var writeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinatorError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: options)
            } catch {
                writeError = error
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        if let writeError {
            throw writeError
        }
    }

    public static func removeItem(at url: URL, coordinated: Bool = ICloudDocumentSync.isEnabled) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        guard coordinated else {
            try FileManager.default.removeItem(at: url)
            return
        }

        var removeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinatorError) { coordinatedURL in
            do {
                try FileManager.default.removeItem(at: coordinatedURL)
            } catch {
                removeError = error
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        if let removeError {
            throw removeError
        }
    }
}

public enum SecureJSONFileCodecError: LocalizedError {
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case invalidEnvelope
    case decryptFailed

    public var errorDescription: String? {
        switch self {
        case .keychainReadFailed:
            return "无法从钥匙串读取本地加密密钥"
        case .keychainWriteFailed:
            return "无法将本地加密密钥保存到钥匙串"
        case .invalidEnvelope:
            return "本地加密文件格式无效"
        case .decryptFailed:
            return "无法解密本地数据"
        }
    }
}

public final class SecureJSONFileCodec {
    private struct Envelope: Codable {
        let format: String
        let algorithm: String
        let payload: String
    }

    private let format = "obelisk.encrypted-json.v1"
    private let algorithm = "AES.GCM"
    private let keyStore: KeychainEncryptionKeyStore
    private let envelopeEncoder = JSONEncoder()
    private let envelopeDecoder = JSONDecoder()

    public init(keyStore: KeychainEncryptionKeyStore = KeychainEncryptionKeyStore()) {
        self.keyStore = keyStore
        envelopeEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func readData(from url: URL) throws -> Data {
        try readData(from: url, coordinated: ICloudDocumentSync.isEnabled)
    }

    public func readData(from url: URL, coordinated: Bool) throws -> Data {
        let data = try CoordinatedFileAccess.readData(from: url, coordinated: coordinated)
        return try decryptIfNeeded(data)
    }

    public func writeData(_ data: Data, to url: URL, options: Data.WritingOptions = [.atomic]) throws {
        let output = try LocalJSONEncryption.isEnabled ? encrypt(data) : data
        try CoordinatedFileAccess.writeData(output, to: url, options: options)
    }

    public func writeData(
        _ data: Data,
        to url: URL,
        encrypted: Bool,
        options: Data.WritingOptions = [.atomic]
    ) throws {
        let output = try encrypted ? encrypt(data) : data
        try CoordinatedFileAccess.writeData(output, to: url, options: options)
    }

    public func writeData(
        _ data: Data,
        to url: URL,
        encrypted: Bool,
        coordinated: Bool,
        options: Data.WritingOptions = [.atomic]
    ) throws {
        let output = try encrypted ? encrypt(data) : data
        try CoordinatedFileAccess.writeData(output, to: url, options: options, coordinated: coordinated)
    }

    public func isEncryptedFile(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return isEncryptedData(data)
    }

    public func rewriteFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let plaintext = try readData(from: url)
        try writeData(plaintext, to: url)
    }

    private func encrypt(_ plaintext: Data) throws -> Data {
        let key = try keyStore.getOrCreateKey()
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw SecureJSONFileCodecError.invalidEnvelope
        }
        let envelope = Envelope(
            format: format,
            algorithm: algorithm,
            payload: combined.base64EncodedString()
        )
        return try envelopeEncoder.encode(envelope)
    }

    private func decryptIfNeeded(_ data: Data) throws -> Data {
        guard isEncryptedData(data) else { return data }
        let envelope = try envelopeDecoder.decode(Envelope.self, from: data)
        guard envelope.format == format, envelope.algorithm == algorithm else {
            throw SecureJSONFileCodecError.invalidEnvelope
        }
        guard let combined = Data(base64Encoded: envelope.payload) else {
            throw SecureJSONFileCodecError.invalidEnvelope
        }
        let key = try keyStore.getOrCreateKey()
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw SecureJSONFileCodecError.decryptFailed
        }
    }

    private func isEncryptedData(_ data: Data) -> Bool {
        guard let envelope = try? envelopeDecoder.decode(Envelope.self, from: data) else {
            return false
        }
        return envelope.format == format && envelope.algorithm == algorithm
    }
}

public final class KeychainEncryptionKeyStore {
    private let service = "local.elidev.Obelisk.encryption"
    private let account = "default-v1"

    public init() {}

    public func getOrCreateKey() throws -> SymmetricKey {
        if let data = try readKeyData() {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try saveKeyData(data)
        return key
    }

    private func readKeyData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SecureJSONFileCodecError.keychainReadFailed(status)
        }
        return data
    }

    private func saveKeyData(_ data: Data) throws {
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureJSONFileCodecError.keychainWriteFailed(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
