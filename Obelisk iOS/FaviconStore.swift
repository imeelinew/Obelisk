import ObeliskCore
import Observation
import UIKit

@MainActor
@Observable
final class FaviconStore {
    private(set) var version = 0

    @ObservationIgnored private let downloader = FaviconDownloader()
    @ObservationIgnored private let imageCache = NSCache<NSString, UIImage>()
    @ObservationIgnored private var inFlight = Set<String>()
    @ObservationIgnored private var failedAt: [String: Date] = [:]

    init() {
        imageCache.countLimit = 256
        imageCache.totalCostLimit = 16 * 1_024 * 1_024
    }

    func cachedImage(for urlString: String) -> UIImage? {
        guard let key = FaviconDownloader.cacheKey(for: urlString) else {
            return nil
        }
        return imageCache.object(forKey: key as NSString)
    }

    func load(_ urlString: String) {
        guard
            let pageURL = URL(string: urlString),
            let key = FaviconDownloader.cacheKey(for: urlString),
            imageCache.object(forKey: key as NSString) == nil,
            !inFlight.contains(key)
        else {
            return
        }

        if let failedAt = failedAt[key], Date().timeIntervalSince(failedAt) < 3_600 {
            return
        }

        inFlight.insert(key)

        let fileURL = cacheDirectory.appendingPathComponent(key)
        if
            let data = try? Data(contentsOf: fileURL),
            let image = UIImage(data: data)
        {
            store(image, for: key)
            inFlight.remove(key)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove(key) }

            guard
                let data = await self.downloader.data(
                    for: pageURL,
                    accepting: { UIImage(data: $0) != nil }
                ),
                let image = UIImage(data: data)
            else {
                self.failedAt[key] = Date()
                return
            }

            do {
                try FileManager.default.createDirectory(
                    at: self.cacheDirectory,
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
            } catch {
                // The in-memory icon is still useful when the cache is unavailable.
            }

            self.failedAt.removeValue(forKey: key)
            self.store(image, for: key)
        }
    }

    private var cacheDirectory: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root
            .appendingPathComponent("com.eli.Obelisk", isDirectory: true)
            .appendingPathComponent("Favicons", isDirectory: true)
    }

    private func store(_ image: UIImage, for key: String) {
        let pixelsWide = Int(image.size.width * image.scale)
        let pixelsHigh = Int(image.size.height * image.scale)
        imageCache.setObject(
            image,
            forKey: key as NSString,
            cost: max(16 * 16 * 4, pixelsWide * pixelsHigh * 4)
        )
        version &+= 1
    }
}
