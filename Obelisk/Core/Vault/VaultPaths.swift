import Foundation

public enum VaultPaths {
    public static let vaultDirectoryName = "Vault"
    public static let versionDirectoryName = "v2"
    public static let blobsDirectoryName = "blobs"
    public static let manifestFileName = "manifest.bin"
    public static let manifestLogicalName = "vault.manifest"

    public static func vaultRoot(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(vaultDirectoryName, isDirectory: true)
    }

    public static func v2Root(in rootDirectory: URL) -> URL {
        vaultRoot(in: rootDirectory)
            .appendingPathComponent(versionDirectoryName, isDirectory: true)
    }

    public static func blobsDirectory(in rootDirectory: URL) -> URL {
        v2Root(in: rootDirectory).appendingPathComponent(blobsDirectoryName, isDirectory: true)
    }

    public static func manifestURL(in rootDirectory: URL) -> URL {
        v2Root(in: rootDirectory).appendingPathComponent(manifestFileName)
    }

    public static func blobURL(in rootDirectory: URL, blobId: UUID) -> URL {
        blobsDirectory(in: rootDirectory).appendingPathComponent("\(blobId.uuidString.lowercased()).bin")
    }

    public static func isVaultV2Present(in rootDirectory: URL) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(in: rootDirectory).path)
    }

    public static let faviconIndexLogicalName = "favicons/index.json"

    public static func faviconIconLogicalName(key: String) -> String {
        "favicons/\(key).png"
    }

    public static func applyVaultDirectoryAttributes(at url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    public static func applyProtectedFileAttributes(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}
