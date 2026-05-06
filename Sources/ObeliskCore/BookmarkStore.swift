import Foundation

public struct Bookmark: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var url: String
    public var createdAt: Date
    public var titleOptimized: Bool
    public var isHidden: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        url: String,
        createdAt: Date = Date(),
        titleOptimized: Bool = false,
        isHidden: Bool = false
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.titleOptimized = titleOptimized
        self.isHidden = isHidden
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, url, createdAt, titleOptimized, isHidden
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        // Older files predate this field; fall back so legacy bookmarks just
        // never show up in "recently added" rather than failing to load.
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? .distantPast
        titleOptimized = (try? c.decode(Bool.self, forKey: .titleOptimized)) ?? false
        isHidden = (try? c.decode(Bool.self, forKey: .isHidden)) ?? false
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
            return "网址格式不正确,需要包含 http:// 或 https://(\(url))"
        case .duplicateURL:
            return "这个网址已经在书签里了"
        case .invalidTitle:
            return "标题不能为空"
        case .lockFailed:
            return "暂时无法保存,书签文件被占用"
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
            .appendingPathComponent("Obelisk")
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
    public func add(title: String, url: String, isHidden: Bool = false) throws -> Bookmark {
        let trimmedURL = try validatedWebURL(url)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw BookmarkStoreError.invalidTitle
        }

        return try withFileLock {
            var database = try load()
            let target = normalizedURL(trimmedURL)
            if database.bookmarks.contains(where: { normalizedURL($0.url) == target }) {
                throw BookmarkStoreError.duplicateURL(trimmedURL)
            }

            let bookmark = Bookmark(title: trimmedTitle, url: trimmedURL, isHidden: isHidden)
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
        try delete(ids: [id])
    }

    public func delete(ids: Set<UUID>) throws {
        guard !ids.isEmpty else {
            return
        }
        try withFileLock {
            var database = try load()
            database.bookmarks.removeAll { ids.contains($0.id) }
            try save(database)
        }
    }

    @discardableResult
    public func applyTitleOptimizations(_ optimizedTitles: [UUID: String]) throws -> Int {
        guard !optimizedTitles.isEmpty else {
            return 0
        }
        return try withFileLock {
            var database = try load()
            var changedCount = 0
            for idx in database.bookmarks.indices {
                let bookmark = database.bookmarks[idx]
                guard !bookmark.titleOptimized,
                      let title = optimizedTitles[bookmark.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty
                else {
                    continue
                }
                if title != bookmark.title {
                    database.bookmarks[idx].title = title
                }
                database.bookmarks[idx].titleOptimized = true
                changedCount += 1
            }
            if changedCount > 0 {
                database.bookmarks.sort {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                try save(database)
            }
            return changedCount
        }
    }

    @discardableResult
    public func update(_ bookmark: Bookmark) throws -> Bookmark {
        let trimmedURL = try validatedWebURL(bookmark.url)
        let trimmedTitle = bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw BookmarkStoreError.invalidTitle
        }

        return try withFileLock {
            var database = try load()
            guard let idx = database.bookmarks.firstIndex(where: { $0.id == bookmark.id }) else {
                return bookmark
            }
            let target = normalizedURL(trimmedURL)
            if database.bookmarks.contains(where: { $0.id != bookmark.id && normalizedURL($0.url) == target }) {
                throw BookmarkStoreError.duplicateURL(trimmedURL)
            }
            var updated = bookmark
            updated.title = trimmedTitle
            updated.url = trimmedURL
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

    private func validatedWebURL(_ rawURL: String) throws -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              parsed.host?.isEmpty == false
        else {
            throw BookmarkStoreError.invalidURL(rawURL)
        }
        return trimmed
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
