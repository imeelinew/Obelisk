import AppKit
import Foundation
import ImageIO
import ObeliskCore
import ObeliskRuntime
import Observation
import os

private struct FaviconRecord: Codable {
  var fetchedAt: Date
  var success: Bool
  var strategyVersion: Int?
}
@MainActor @Observable private final class FaviconRevision { var value = 0 }

/// Window networking belongs to the disposable UI process
/// The host serves compressed disk data and downloads only for an open status menu
@MainActor @Observable
final class FaviconLoader {
  @ObservationIgnored var onIconLoaded: ((String?) -> Void)?
  private(set) var version = 0
  @ObservationIgnored private var imageRevisions: [String: FaviconRevision] = [:]
  @ObservationIgnored private let client: LibraryClient?
  @ObservationIgnored private let rootDirectory: URL
  @ObservationIgnored private let images = NSCache<NSString, NSImage>()
  @ObservationIgnored private var index: [String: FaviconRecord] = [:]
  @ObservationIgnored private let downloader = FaviconDownloader()
  @ObservationIgnored private var reading: Set<String> = []
  @ObservationIgnored private var queued: Set<String> = []
  @ObservationIgnored private var pending: [(URL, String)] = []
  @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var generation = UUID()
  private let log = Logger(subsystem: "com.eli.Obelisk", category: "Favicon")

  init(rootDirectory: URL, client: LibraryClient? = nil) {
    self.rootDirectory = rootDirectory
    self.client = client
    images.countLimit = 256
    images.totalCostLimit = client == nil ? 1_024 * 1_024 : 8 * 1_024 * 1_024
    if client == nil { loadIndex() }
  }
  private var indexURL: URL { ObeliskPrivateStorage.faviconIndexURL(rootDirectory: rootDirectory) }
  private func iconURL(_ key: String) -> URL {
    ObeliskPrivateStorage.faviconIconURL(rootDirectory: rootDirectory, key: key)
  }

  func imageVersion(for url: String) -> Int {
    guard let key = FaviconDownloader.cacheKey(for: url) else { return 0 }
    if imageRevisions[key] == nil { imageRevisions[key] = FaviconRevision() }
    return imageRevisions[key]!.value
  }
  func image(for url: String) -> NSImage? {
    guard let key = FaviconDownloader.cacheKey(for: url), let page = URL(string: url) else {
      return nil
    }
    if let image = images.object(forKey: key as NSString) { return image }
    if client != nil {
      Task { _ = await loadImage(for: url) }
      return nil
    }
    let cached = cachedData(for: url)
    if cached.shouldFetch { enqueue(page, key: key) }
    guard let data = cached.data, let image = Self.decode(data) else { return nil }
    cache(image, key: key)
    return image
  }
  func loadImage(for url: String) async -> NSImage? {
    guard let key = FaviconDownloader.cacheKey(for: url), let page = URL(string: url) else {
      return nil
    }
    if let image = images.object(forKey: key as NSString) { return image }
    guard let client else { return image(for: url) }
    guard reading.insert(key).inserted else { return nil }
    defer { reading.remove(key) }
    let currentGeneration = generation
    var request = RuntimeRequest(.favicon)
    request.url = url
    guard let cached: RuntimeFavicon = try? await client.request(request), !Task.isCancelled,
      generation == currentGeneration
    else { return nil }
    if cached.shouldFetch { enqueue(page, key: key) }
    guard let data = cached.data, let image = Self.decode(data) else { return nil }
    cache(image, key: key)
    changed(key)
    return image
  }

  /// This path never decodes an image or starts a network request in the host
  func cachedData(for url: String) -> RuntimeFavicon {
    guard let key = FaviconDownloader.cacheKey(for: url) else {
      return RuntimeFavicon(data: nil, shouldFetch: false)
    }
    let data = try? Data(contentsOf: iconURL(key), options: .mappedIfSafe)
    let record = index[key]
    let age = record.map { Date().timeIntervalSince($0.fetchedAt) } ?? .infinity
    let fresh = data != nil && record?.success == true && age < 30 * 24 * 3600
    let failed = record?.success == false && record?.strategyVersion == 2 && age < 7 * 24 * 3600
    return RuntimeFavicon(data: data, shouldFetch: !fresh && !failed)
  }

  func storeDownloadedData(_ data: Data, key: String) throws {
    guard key.count == 16, key.allSatisfy({ $0.isHexDigit }), data.count <= 256 * 1_024,
      let image = Self.decode(data), let normalized = Self.png(image)
    else { throw RuntimeError.invalidRequest }
    try LocalFileAccess.writeData(normalized, to: iconURL(key))
    index[key] = FaviconRecord(fetchedAt: Date(), success: true, strategyVersion: 2)
    saveIndex()
    images.removeObject(forKey: key as NSString)
    changed(key)
    onIconLoaded?(key)
  }
  func storeFailure(key: String) throws {
    guard key.count == 16, key.allSatisfy({ $0.isHexDigit }) else {
      throw RuntimeError.invalidRequest
    }
    index[key] = FaviconRecord(fetchedAt: Date(), success: false, strategyVersion: 2)
    saveIndex()
  }
  func invalidateDiskData(for url: String) {
    guard let key = FaviconDownloader.cacheKey(for: url) else { return }
    try? LocalFileAccess.removeItem(at: iconURL(key))
    index.removeValue(forKey: key)
    images.removeObject(forKey: key as NSString)
    saveIndex()
    changed(key)
  }
  func refresh(urlString: String) {
    guard let key = FaviconDownloader.cacheKey(for: urlString), let page = URL(string: urlString)
    else { return }
    if let client {
      var r = RuntimeRequest(.refreshFavicon)
      r.url = urlString
      Task {
        let _: Bool? = try? await client.request(r)
        images.removeObject(forKey: key as NSString)
        changed(key)
        enqueue(page, key: key)
      }
    } else {
      invalidateDiskData(for: urlString)
      enqueue(page, key: key)
    }
  }
  func invalidate(key: String?) {
    if let key {
      images.removeObject(forKey: key as NSString)
      changed(key)
    } else {
      reloadStorage()
    }
  }
  func reloadStorage() {
    images.removeAllObjects()
    if client == nil { loadIndex() }
    for revision in imageRevisions.values { revision.value &+= 1 }
    version &+= 1
  }
  func releaseTransientMemory() {
    generation = UUID()
    images.removeAllObjects()
    reading.removeAll()
    pending.removeAll()
    queued.removeAll()
    for task in downloads.values { task.cancel() }
    downloads.removeAll()
    downloader.cancelAllTasks()
  }
  private func enqueue(_ page: URL, key: String) {
    guard queued.insert(key).inserted else { return }
    pending.append((page, key))
    drain()
  }
  private func drain() {
    while downloads.count < 4, !pending.isEmpty {
      let (page, key) = pending.removeFirst()
      let currentGeneration = generation
      downloads[key] = Task { [weak self] in
        guard let self else { return }
        defer {
          if generation == currentGeneration {
            downloads.removeValue(forKey: key)
            queued.remove(key)
            drain()
          }
        }
        let data = await downloader.data(for: page) { NSImage(data: $0) != nil }
        guard !Task.isCancelled, generation == currentGeneration else { return }
        guard let data, let image = Self.decode(data), let png = Self.png(image) else {
          if let client {
            var r = RuntimeRequest(.saveFavicon)
            r.title = key
            let _: Bool? = try? await client.request(r)
          } else {
            try? storeFailure(key: key)
          }
          return
        }
        do {
          if let client {
            var r = RuntimeRequest(.saveFavicon)
            r.title = key
            r.data = png
            let _: Bool = try await client.request(r)
          } else {
            try storeDownloadedData(png, key: key)
          }
          guard !Task.isCancelled else { return }
          cache(image, key: key)
          changed(key)
        } catch { log.error("Favicon cache write: \(error.localizedDescription)") }
      }
    }
  }
  private func cache(_ image: NSImage, key: String) {
    images.setObject(image, forKey: key as NSString, cost: 48 * 48 * 4)
  }
  private func changed(_ key: String) {
    imageRevisions[key]?.value &+= 1
    version &+= 1
  }
  private static func decode(_ data: Data) -> NSImage? {
    if let source = CGImageSourceCreateWithData(data as CFData, nil),
      let bitmap = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 48,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    {
      return NSImage(cgImage: bitmap, size: NSSize(width: 16, height: 16))
    }
    // Vector formats use a fixed-size destination rather than an unbounded raster
    guard let vector = NSImage(data: data),
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    vector.draw(in: NSRect(x: 0, y: 0, width: 48, height: 48))
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: NSSize(width: 16, height: 16))
    image.addRepresentation(bitmap)
    return image
  }
  private static func png(_ image: NSImage) -> Data? {
    guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }
    return NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:])
  }
  private func loadIndex() {
    guard let data = try? Data(contentsOf: indexURL) else {
      index = [:]
      return
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    index = (try? decoder.decode([String: FaviconRecord].self, from: data)) ?? [:]
  }
  private func saveIndex() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    do { try LocalFileAccess.writeData(try encoder.encode(index), to: indexURL) } catch {
      log.error("Favicon index write: \(error.localizedDescription)")
    }
  }
}
