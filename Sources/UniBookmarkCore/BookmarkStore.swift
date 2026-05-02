import Foundation

public struct Bookmark: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var url: String
    public var createdAt: Date
    public var pinned: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        url: String,
        createdAt: Date = Date(),
        pinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, url, createdAt, pinned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        // Older files predate this field; fall back so legacy bookmarks just
        // never show up in "recently added" rather than failing to load.
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? .distantPast
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
    }
}

public struct BookmarkDatabase: Codable, Equatable {
    public var version: Int
    public var bookmarks: [Bookmark]

    public init(version: Int = 1, bookmarks: [Bookmark] = []) {
        self.version = version
        self.bookmarks = bookmarks
    }
}

public enum BookmarkStoreError: LocalizedError {
    case invalidURL(String)
    case duplicateURL(String)
    case invalidTitle
    case lockFailed

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .duplicateURL(let url):
            return "Bookmark already exists: \(url)"
        case .invalidTitle:
            return "Title must not be empty"
        case .lockFailed:
            return "Failed to acquire bookmark store lock"
        }
    }
}

public final class BookmarkStore {
    public let rootDirectory: URL
    public let fileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootDirectory: URL = BookmarkStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
        self.fileURL = rootDirectory.appendingPathComponent("bookmarks.json")

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultRootDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["UNIBOOKMARK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }

        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("UniBookmark")
    }

    public func load() throws -> BookmarkDatabase {
        try ensureStoreExists()
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(BookmarkDatabase.self, from: data)
    }

    public func save(_ database: BookmarkDatabase) throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(database)
        try data.write(to: fileURL, options: [.atomic])
    }

    @discardableResult
    public func add(title: String, url: String) throws -> Bookmark {
        guard URL(string: url)?.scheme != nil else {
            throw BookmarkStoreError.invalidURL(url)
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw BookmarkStoreError.invalidTitle
        }

        return try withFileLock {
            var database = try load()
            let target = normalizedURL(url)
            if database.bookmarks.contains(where: { normalizedURL($0.url) == target }) {
                throw BookmarkStoreError.duplicateURL(url)
            }

            let bookmark = Bookmark(title: trimmedTitle, url: url)
            database.bookmarks.append(bookmark)
            database.bookmarks.sort {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            try save(database)
            return bookmark
        }
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let lockURL = rootDirectory.appendingPathComponent(".lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw BookmarkStoreError.lockFailed
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw BookmarkStoreError.lockFailed
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    public func bookmarks() throws -> [Bookmark] {
        try load().bookmarks
    }

    public func delete(id: UUID) throws {
        try withFileLock {
            var database = try load()
            database.bookmarks.removeAll { $0.id == id }
            try save(database)
        }
    }

    @discardableResult
    public func setPinned(id: UUID, pinned: Bool) throws -> Bookmark? {
        try withFileLock {
            var database = try load()
            guard let idx = database.bookmarks.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            database.bookmarks[idx].pinned = pinned
            let updated = database.bookmarks[idx]
            database.bookmarks.sort {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            try save(database)
            return updated
        }
    }

    @discardableResult
    public func update(_ bookmark: Bookmark) throws -> Bookmark {
        guard URL(string: bookmark.url)?.scheme != nil else {
            throw BookmarkStoreError.invalidURL(bookmark.url)
        }
        let trimmedTitle = bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw BookmarkStoreError.invalidTitle
        }

        return try withFileLock {
            var database = try load()
            guard let idx = database.bookmarks.firstIndex(where: { $0.id == bookmark.id }) else {
                return bookmark
            }
            let target = normalizedURL(bookmark.url)
            if database.bookmarks.contains(where: { $0.id != bookmark.id && normalizedURL($0.url) == target }) {
                throw BookmarkStoreError.duplicateURL(bookmark.url)
            }
            var updated = bookmark
            updated.title = trimmedTitle
            database.bookmarks[idx] = updated
            database.bookmarks.sort {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            try save(database)
            return updated
        }
    }

    private func ensureStoreExists() throws {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try save(BookmarkDatabase())
    }

    private func normalizedURL(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return rawURL
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil

        if let port = components.port,
           (components.scheme == "https" && port == 443) || (components.scheme == "http" && port == 80) {
            components.port = nil
        }

        if components.path == "/" {
            components.path = ""
        } else if components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        if let items = components.queryItems {
            components.queryItems = items.sorted { $0.name < $1.name }
        }

        return components.string ?? rawURL
    }
}
