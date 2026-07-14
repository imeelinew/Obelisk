import AppKit
import Foundation
import ObeliskCore
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
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var index: [String: FaviconRecord] = [:]
    @ObservationIgnored private let imageCache = NSCache<NSString, NSImage>()
    @ObservationIgnored private let downloader = FaviconDownloader()

    /// Cached icons older than this are refreshed in the background.
    @ObservationIgnored private let positiveTTL: TimeInterval = 30 * 24 * 3600
    /// Failed lookups are not retried for this long.
    @ObservationIgnored private let negativeTTL: TimeInterval = 7 * 24 * 3600
    @ObservationIgnored private let faviconFetchStrategyVersion = 2

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        imageCache.countLimit = 256
        imageCache.totalCostLimit = 8 * 1_024 * 1_024
        loadIndex()
    }

    private var cacheDirectory: URL {
        ObeliskPrivateStorage.faviconDirectory(in: rootDirectory)
    }

    private var indexURL: URL {
        ObeliskPrivateStorage.faviconIndexURL(rootDirectory: rootDirectory)
    }

    private func iconURL(for key: String) -> URL {
        ObeliskPrivateStorage.faviconIconURL(rootDirectory: rootDirectory, key: key)
    }

    func image(for urlString: String) -> NSImage? {
        guard
            let pageURL = URL(string: urlString),
            let key = FaviconDownloader.cacheKey(for: urlString)
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
            let key = FaviconDownloader.cacheKey(for: urlString)
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

    /// Drops window-driven image and networking state while preserving the
    /// small on-disk favicon index used by the menu bar. The next image lookup
    /// repopulates the cache lazily.
    func releaseTransientMemory() {
        imageCache.removeAllObjects()
        inFlight.removeAll()
        downloader.cancelAllTasks()
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
        await downloader.data(for: pageURL) { data in
            NSImage(data: data) != nil
        }
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
        guard let data = try? LocalFileAccess.readData(from: indexURL) else {
            index = [:]
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: FaviconRecord].self, from: data) {
            index = decoded
        } else {
            index = [:]
        }
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
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(index)
            try LocalFileAccess.writeData(data, to: indexURL)
        } catch {
            faviconLog.error("Failed to persist favicon index: \(error.localizedDescription)")
        }
    }

    private func imageFromCache(at url: URL) -> NSImage? {
        guard let data = try? LocalFileAccess.readData(from: url) else { return nil }
        return NSImage(data: data)
    }

    private func readCacheData(from url: URL) throws -> Data {
        try LocalFileAccess.readData(from: url)
    }

    private func writeCacheData(_ data: Data, to url: URL) throws {
        try LocalFileAccess.writeData(data, to: url)
    }
}
