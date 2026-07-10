import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import os

private let faviconLog = Logger(subsystem: "com.eli.Obelisk", category: "Favicon")

private struct FaviconRecord: Codable {
    var fetchedAt: Date
    var success: Bool
    var strategyVersion: Int?
}

@MainActor
@Observable
final class FaviconLoader {
    @ObservationIgnored var onIconLoaded: (() -> Void)?
    /// Bumped whenever a new favicon lands on disk. Views that read this
    /// in their body get re-rendered so cached lookups pick up new icons.
    private(set) var version: Int = 0

    @ObservationIgnored private var rootDirectory: URL
    @ObservationIgnored private let secureCodec = SecureJSONFileCodec()
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var index: [String: FaviconRecord] = [:]
    @ObservationIgnored private let imageCache = NSCache<NSString, NSImage>()
    @ObservationIgnored private let session: URLSession

    /// Cached icons older than this are refreshed in the background.
    @ObservationIgnored private let positiveTTL: TimeInterval = 30 * 24 * 3600
    /// Failed lookups are not retried for this long.
    @ObservationIgnored private let negativeTTL: TimeInterval = 7 * 24 * 3600
    @ObservationIgnored private let faviconFetchStrategyVersion = 2

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Obelisk/1.0"
        ]
        self.session = URLSession(configuration: configuration)
        imageCache.countLimit = 256
        imageCache.totalCostLimit = 8 * 1_024 * 1_024
        loadIndex()
    }

    private var cacheDirectory: URL {
        cacheDirectory(encrypted: LocalJSONEncryption.isEnabled)
    }

    private var indexURL: URL {
        indexURL(encrypted: LocalJSONEncryption.isEnabled)
    }

    private func iconURL(for key: String) -> URL {
        iconURL(for: key, encrypted: LocalJSONEncryption.isEnabled)
    }

    private func cacheDirectory(encrypted: Bool) -> URL {
        ObeliskPrivateStorage.faviconDirectory(in: rootDirectory, encrypted: encrypted)
    }

    private func indexURL(encrypted: Bool) -> URL {
        ObeliskPrivateStorage.faviconIndexURL(rootDirectory: rootDirectory, encrypted: encrypted)
    }

    private func iconURL(for key: String, encrypted: Bool) -> URL {
        ObeliskPrivateStorage.faviconIconURL(rootDirectory: rootDirectory, key: key, encrypted: encrypted)
    }

    func image(for urlString: String) -> NSImage? {
        guard
            let pageURL = URL(string: urlString),
            let key = cacheKey(for: pageURL)
        else {
            return nil
        }

        let fileURL = iconURL(for: key)
        let record = index[key]
        let now = Date()
        let cacheKey = key as NSString

        if let image = imageCache.object(forKey: cacheKey) {
            let copy = image.copy() as? NSImage ?? image
            copy.size = NSSize(width: 16, height: 16)
            if let record, now.timeIntervalSince(record.fetchedAt) > positiveTTL {
                fetchIfNeeded(pageURL: pageURL, key: key, fileURL: fileURL)
            }
            return copy
        }

        if let image = imageFromCache(at: fileURL) {
            // Copy before mutating size; the underlying NSImage may be cached
            // and shared, and changing size on a shared instance can affect
            // unrelated rendering elsewhere.
            let copy = image.copy() as? NSImage ?? image
            copy.size = NSSize(width: 16, height: 16)
            imageCache.setObject(copy, forKey: cacheKey, cost: Self.memoryCost(of: copy))

            // Refresh stale icons in the background — keep showing the cached one.
            if let record, now.timeIntervalSince(record.fetchedAt) > positiveTTL {
                fetchIfNeeded(pageURL: pageURL, key: key, fileURL: fileURL)
            }
            return copy
        }

        // Negative cache: don't hammer sites that recently failed.
        if let record,
           !record.success,
           record.strategyVersion == faviconFetchStrategyVersion,
           now.timeIntervalSince(record.fetchedAt) < negativeTTL {
            return nil
        }

        fetchIfNeeded(pageURL: pageURL, key: key, fileURL: fileURL)
        return nil
    }

    func refresh(urlString: String) {
        guard
            let pageURL = URL(string: urlString),
            let key = cacheKey(for: pageURL)
        else {
            return
        }

        let fileURL = iconURL(for: key)
        try? LocalFileAccess.removeItem(at: fileURL)
        imageCache.removeObject(forKey: key as NSString)
        index.removeValue(forKey: key)
        saveIndex()
        version &+= 1
        onIconLoaded?()
        fetchIfNeeded(pageURL: pageURL, key: key, fileURL: fileURL)
    }

    func refreshAll(urlStrings: [String]) {
        clearStorage()
        inFlight.removeAll()
        index.removeAll()
        imageCache.removeAllObjects()
        saveIndex()
        version &+= 1
        onIconLoaded?()

        for urlString in Set(urlStrings) {
            _ = image(for: urlString)
        }
    }

    func reloadStorage() {
        inFlight.removeAll()
        index.removeAll()
        imageCache.removeAllObjects()
        loadIndex()
        version &+= 1
        onIconLoaded?()
    }

    func updateRootDirectory(_ rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        reloadStorage()
    }

    func clearStorage() {
        for location in faviconStorageLocations() {
            try? LocalFileAccess.removeItem(at: location.directory)
        }
        ObeliskStorageMigrator.removeEmptyStorageDirectories(in: rootDirectory)
        imageCache.removeAllObjects()
    }

    /// Drops window-driven image and networking state while preserving the
    /// small on-disk favicon index used by the menu bar. The next image lookup
    /// repopulates the cache lazily.
    func releaseTransientMemory() {
        imageCache.removeAllObjects()
        inFlight.removeAll()
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    private struct FaviconStorageLocation {
        let directory: URL
        let encrypted: Bool
    }

    private func indexURL(in location: FaviconStorageLocation) -> URL {
        ObeliskPrivateStorage.faviconIndexURL(
            directory: location.directory,
            encrypted: location.encrypted
        )
    }

    private func faviconStorageLocations() -> [FaviconStorageLocation] {
        uniqueFaviconLocations([
            FaviconStorageLocation(
                directory: ObeliskPrivateStorage.faviconDirectory(in: rootDirectory),
                encrypted: LocalJSONEncryption.isEnabled
            )
        ])
    }

    private func uniqueFaviconLocations(_ locations: [FaviconStorageLocation]) -> [FaviconStorageLocation] {
        var seen = Set<String>()
        return locations.filter { seen.insert($0.directory.standardizedFileURL.path).inserted }
    }

    private func fetchIfNeeded(pageURL: URL, key: String, fileURL: URL) {
        guard !inFlight.contains(key) else {
            return
        }

        inFlight.insert(key)
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer {
                self.inFlight.remove(key)
            }

            let data = await self.downloadFaviconData(for: pageURL)
            guard
                let data,
                let image = NSImage(data: data),
                let pngData = Self.pngData(from: image)
            else {
                self.recordResult(key: key, success: false)
                return
            }

            do {
                try FileManager.default.createDirectory(
                    at: self.cacheDirectory,
                    withIntermediateDirectories: true
                )
                try self.writeCacheData(pngData, to: fileURL)
                image.size = NSSize(width: 16, height: 16)
                self.imageCache.setObject(
                    image,
                    forKey: key as NSString,
                    cost: Self.memoryCost(of: image)
                )
                self.recordResult(key: key, success: true)
                self.version &+= 1
                self.onIconLoaded?()
            } catch {
                self.recordResult(key: key, success: false)
            }
        }
    }

    private func downloadFaviconData(for pageURL: URL) async -> Data? {
        // Strategy: fetch the page HTML first and rank discovered icons by
        // declared `sizes`, falling back to the well-known root paths if the
        // page has no usable hints (or fails to load).
        if let html = await downloadText(from: pageURL) {
            for url in discoveredIconURLs(in: html, baseURL: pageURL) {
                if let data = await downloadImageData(from: url) {
                    return data
                }
            }
        }

        for url in directFaviconURLs(for: pageURL) {
            if let data = await downloadImageData(from: url) {
                return data
            }
        }

        for url in fallbackFaviconURLs(for: pageURL) {
            if let data = await downloadImageData(from: url) {
                return data
            }
        }
        return nil
    }

    private func directFaviconURLs(for pageURL: URL) -> [URL] {
        guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else {
            return []
        }

        components.path = ""
        components.query = nil
        components.fragment = nil

        guard let origin = components.url else {
            return []
        }

        return [
            origin.appendingPathComponent("apple-touch-icon.png"),
            origin.appendingPathComponent("favicon.png"),
            origin.appendingPathComponent("favicon.ico")
        ]
    }

    private func fallbackFaviconURLs(for pageURL: URL) -> [URL] {
        guard
            let host = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)?.host?.lowercased(),
            shouldUseExternalFaviconFallback(for: host),
            let duckDuckGoURL = URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")
        else {
            return []
        }

        return [duckDuckGoURL]
    }

    private func shouldUseExternalFaviconFallback(for host: String) -> Bool {
        guard host.contains("."),
              host != "localhost",
              !host.hasSuffix(".local"),
              IPv4Address(host) == nil,
              IPv6Address(host) == nil
        else {
            return false
        }

        return true
    }

    private func downloadImageData(from url: URL) async -> Data? {
        let maxImageBytes = 1_048_576
        guard let (data, response) = try? await session.data(from: url) else {
            return nil
        }

        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            return nil
        }

        if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let byteCount = Int(contentLength), byteCount > maxImageBytes {
            return nil
        }

        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            let allowed = ["image/png", "image/x-icon", "image/vnd.microsoft.icon", "image/gif", "image/svg+xml", "image/webp", "image/jpeg"]
            guard allowed.contains(where: { contentType.hasPrefix($0) }) else {
                return nil
            }
        }

        guard data.count <= maxImageBytes, NSImage(data: data) != nil else {
            return nil
        }

        return data
    }

    private func downloadText(from url: URL) async -> String? {
        guard let (data, response) = try? await session.data(from: url) else {
            return nil
        }

        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Parse all `<link rel="...icon...">` tags, score by declared size, and
    /// return URLs sorted best-first. Apple-touch-icons get a small bonus
    /// since they are reliably square and high-DPI; mask-icons (monochrome
    /// SVG glyphs) get a penalty since they render badly as menu favicons.
    private func discoveredIconURLs(in html: String, baseURL: URL) -> [URL] {
        let linkPattern = #"(?s)<link\b[^>]*>"#
        let attrPattern = #"(?s)([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#

        guard
            let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive]),
            let attrRegex = try? NSRegularExpression(pattern: attrPattern, options: [.caseInsensitive])
        else {
            return []
        }

        struct Candidate {
            var score: Int
            var url: URL
        }

        var candidates: [Candidate] = []
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)

        for match in linkRegex.matches(in: html, range: fullRange) {
            guard let linkRange = Range(match.range, in: html) else { continue }
            let tag = String(html[linkRange])
            let tagNS = NSRange(tag.startIndex..<tag.endIndex, in: tag)

            var attrs: [String: String] = [:]
            for attrMatch in attrRegex.matches(in: tag, range: tagNS) {
                guard let nameRange = Range(attrMatch.range(at: 1), in: tag) else { continue }
                let name = tag[nameRange].lowercased()
                let value: String
                if let r = Range(attrMatch.range(at: 2), in: tag) {
                    value = String(tag[r])
                } else if let r = Range(attrMatch.range(at: 3), in: tag) {
                    value = String(tag[r])
                } else if let r = Range(attrMatch.range(at: 4), in: tag) {
                    value = String(tag[r])
                } else {
                    continue
                }
                attrs[name] = value
            }

            guard
                let rel = attrs["rel"]?.lowercased(),
                rel.contains("icon"),
                let href = attrs["href"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !href.isEmpty,
                let url = URL(string: href, relativeTo: baseURL)?.absoluteURL
            else {
                continue
            }

            let isAppleTouch = rel.contains("apple-touch-icon")
            let isMask = rel.contains("mask-icon")
            let dim = parseSizeAttribute(attrs["sizes"])
            // Score: declared dimension dominates; type provides a tiebreak.
            var score = dim
            if isAppleTouch { score += 64 }
            if isMask { score -= 10_000 }
            candidates.append(Candidate(score: score, url: url))
        }

        // Stable sort, best-first; dedupe by URL.
        var seen = Set<URL>()
        return candidates
            .sorted { $0.score > $1.score }
            .filter { seen.insert($0.url).inserted }
            .map { $0.url }
    }

    /// Parse a `sizes` attribute like "32x32 64x64" or "any". Returns the
    /// largest declared edge length, or 0 if unknown. "any" is treated as a
    /// large value so SVG icons rank above tiny rasters.
    private func parseSizeAttribute(_ raw: String?) -> Int {
        guard let raw = raw?.lowercased() else { return 0 }
        if raw.contains("any") { return 1024 }
        var maxDim = 0
        for token in raw.split(whereSeparator: { $0.isWhitespace }) {
            let parts = token.split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { continue }
            maxDim = max(maxDim, min(w, h))
        }
        return maxDim
    }

    private func cacheKey(for url: URL) -> String? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host?.lowercased()
        else {
            return nil
        }

        let identity = components.port.map { "\(host):\($0)" } ?? host
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private static func memoryCost(of image: NSImage) -> Int {
        let representationCost = image.representations.reduce(0) { total, representation in
            total + max(0, representation.pixelsWide) * max(0, representation.pixelsHigh) * 4
        }
        return max(16 * 16 * 4, representationCost)
    }

    // MARK: - Index persistence

    private func loadIndex() {
        index = loadIndex(encrypted: LocalJSONEncryption.isEnabled)
    }

    private func loadIndex(encrypted: Bool) -> [String: FaviconRecord] {
        loadIndex(in: FaviconStorageLocation(directory: cacheDirectory(encrypted: encrypted), encrypted: encrypted))
    }

    private func loadIndex(in location: FaviconStorageLocation) -> [String: FaviconRecord] {
        guard let data = try? readCacheData(from: indexURL(in: location), encrypted: location.encrypted) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: FaviconRecord].self, from: data) {
            return decoded
        }
        return [:]
    }

    private func recordResult(key: String, success: Bool) {
        index[key] = FaviconRecord(
            fetchedAt: Date(),
            success: success,
            strategyVersion: faviconFetchStrategyVersion
        )
        saveIndex()
    }

    private func saveIndex() {
        saveIndex(index, encrypted: LocalJSONEncryption.isEnabled)
    }

    private func saveIndex(_ index: [String: FaviconRecord], encrypted: Bool) {
        saveIndex(index, in: FaviconStorageLocation(directory: cacheDirectory(encrypted: encrypted), encrypted: encrypted))
    }

    private func saveIndex(_ index: [String: FaviconRecord], in location: FaviconStorageLocation) {
        do {
            try FileManager.default.createDirectory(
                at: location.directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(index)
            try writeCacheData(data, to: indexURL(in: location), encrypted: location.encrypted)
        } catch {
            faviconLog.error("Failed to persist favicon index: \(error.localizedDescription)")
        }
    }

    private func imageFromCache(at url: URL) -> NSImage? {
        guard let data = try? readCacheData(from: url) else { return nil }
        return NSImage(data: data)
    }

    private func readCacheData(from url: URL) throws -> Data {
        try readCacheData(from: url, encrypted: LocalJSONEncryption.isEnabled)
    }

    private func readCacheData(from url: URL, encrypted: Bool) throws -> Data {
        if encrypted {
            return try secureCodec.readData(from: url)
        }
        return try LocalFileAccess.readData(from: url)
    }

    private func writeCacheData(_ data: Data, to url: URL) throws {
        try writeCacheData(data, to: url, encrypted: LocalJSONEncryption.isEnabled)
    }

    private func writeCacheData(_ data: Data, to url: URL, encrypted: Bool) throws {
        if encrypted {
            try secureCodec.writeData(
                data,
                to: url,
                encrypted: true
            )
        } else {
            try LocalFileAccess.writeData(data, to: url)
        }
    }
}
