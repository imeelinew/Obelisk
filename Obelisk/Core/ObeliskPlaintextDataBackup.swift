import Foundation

/// Explicit, authenticated export of a point-in-time plaintext snapshot.
enum ObeliskPlaintextDataBackup {
    struct Result: Sendable {
        let destinationURL: URL
        let exportedJSONFiles: [String]
        let exportedFaviconCount: Int
    }

    enum BackupError: LocalizedError {
        case destinationAlreadyExists(URL)
        case nothingToExport

        var errorDescription: String? {
            switch self {
            case .destinationAlreadyExists(let url):
                return "备份目录已存在：\(url.lastPathComponent)"
            case .nothingToExport:
                return "没有可备份的数据"
            }
        }
    }

    static func createBackup(
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

        let payload = try ObeliskVaultStore(rootDirectory: rootDirectory).validate()
        try fileManager.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let payloadData = try encoder.encode(payload)
        let payloadURL = destinationRoot.appendingPathComponent("payload.json")
        try LocalFileAccess.writeData(payloadData, to: payloadURL)

        let faviconCount = try exportFavicons(
            from: ObeliskPrivateStorage.faviconDirectory(in: rootDirectory),
            to: destinationRoot.appendingPathComponent("Favicons", isDirectory: true)
        )
        return Result(
            destinationURL: destinationRoot,
            exportedJSONFiles: ["payload.json"],
            exportedFaviconCount: faviconCount
        )
    }

    private static func backupFolderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Backup-" + formatter.string(from: date)
    }

    private static func exportFavicons(from source: URL, to destination: URL) throws -> Int {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return 0 }
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let files = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var iconCount = 0
        for sourceURL in files {
            let isFile = try sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            guard isFile else { continue }
            let destinationURL = destination.appendingPathComponent(sourceURL.lastPathComponent)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
            if sourceURL.pathExtension.lowercased() == "png" { iconCount += 1 }
        }
        return iconCount
    }
}
