import Foundation
import ObeliskData

enum ObeliskPrivateStorage {
    static func faviconDirectory(in rootDirectory: URL) -> URL {
        if BookmarkStore.environmentRootOverride() != nil {
            return rootDirectory
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("Favicons", isDirectory: true)
        }
        let fileManager = FileManager.default
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
        return cacheRoot
            .appendingPathComponent("com.eli.Obelisk", isDirectory: true)
            .appendingPathComponent("Favicons", isDirectory: true)
    }

    static func faviconIndexURL(rootDirectory: URL) -> URL {
        faviconDirectory(in: rootDirectory).appendingPathComponent("index.json")
    }

    static func faviconIconURL(rootDirectory: URL, key: String) -> URL {
        faviconDirectory(in: rootDirectory).appendingPathComponent("\(key).png")
    }
}

enum LocalFileAccess {
    static func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    static func writeData(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions = [.atomic]
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: options)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func removeItem(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
