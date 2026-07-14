import CryptoKit
import Foundation
import Network

public struct FaviconDownloader: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpAdditionalHeaders = ["User-Agent": "Obelisk/1.0"]
        session = URLSession(configuration: configuration)
    }

    public func data(
        for pageURL: URL,
        accepting: @Sendable (Data) -> Bool
    ) async -> Data? {
        let html = await downloadText(from: pageURL)
        for url in Self.candidateURLs(in: html, for: pageURL) {
            if let data = await downloadImageData(from: url, accepting: accepting) {
                return data
            }
        }
        return nil
    }

    public func cancelAllTasks() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    public static func cacheKey(for urlString: String) -> String? {
        guard
            let url = URL(string: urlString),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host?.lowercased()
        else {
            return nil
        }

        let identity = components.port.map { "\(host):\($0)" } ?? host
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func candidateURLs(in html: String?, for pageURL: URL) -> [URL] {
        var urls: [URL] = []
        if let html {
            urls.append(contentsOf: discoveredIconURLs(in: html, baseURL: pageURL))
        }
        urls.append(contentsOf: directFaviconURLs(for: pageURL))
        urls.append(contentsOf: fallbackFaviconURLs(for: pageURL))

        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    private func downloadImageData(
        from url: URL,
        accepting: @Sendable (Data) -> Bool
    ) async -> Data? {
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
            let allowed = [
                "image/png",
                "image/x-icon",
                "image/vnd.microsoft.icon",
                "image/gif",
                "image/svg+xml",
                "image/webp",
                "image/jpeg",
            ]
            guard allowed.contains(where: { contentType.hasPrefix($0) }) else {
                return nil
            }
        }

        guard data.count <= maxImageBytes, accepting(data) else {
            return nil
        }
        return data
    }

    private func downloadText(from url: URL) async -> String? {
        let maxHTMLBytes = 2_097_152
        guard let (data, response) = try? await session.data(from: url) else {
            return nil
        }
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            data.count <= maxHTMLBytes
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func directFaviconURLs(for pageURL: URL) -> [URL] {
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
            origin.appendingPathComponent("favicon.ico"),
        ]
    }

    private static func fallbackFaviconURLs(for pageURL: URL) -> [URL] {
        guard
            let host = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)?.host?.lowercased(),
            host.contains("."),
            host != "localhost",
            !host.hasSuffix(".local"),
            IPv4Address(host) == nil,
            IPv6Address(host) == nil,
            let url = URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")
        else {
            return []
        }
        return [url]
    }

    private static func discoveredIconURLs(in html: String, baseURL: URL) -> [URL] {
        let linkPattern = #"(?s)<link\b[^>]*>"#
        let attrPattern = #"(?s)([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#

        guard
            let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive]),
            let attrRegex = try? NSRegularExpression(pattern: attrPattern, options: [.caseInsensitive])
        else {
            return []
        }

        struct Candidate {
            let score: Int
            let url: URL
        }

        var candidates: [Candidate] = []
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)

        for match in linkRegex.matches(in: html, range: fullRange) {
            guard let linkRange = Range(match.range, in: html) else { continue }
            let tag = String(html[linkRange])
            let tagRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)
            var attributes: [String: String] = [:]

            for attributeMatch in attrRegex.matches(in: tag, range: tagRange) {
                guard let nameRange = Range(attributeMatch.range(at: 1), in: tag) else { continue }
                let value: String
                if let range = Range(attributeMatch.range(at: 2), in: tag) {
                    value = String(tag[range])
                } else if let range = Range(attributeMatch.range(at: 3), in: tag) {
                    value = String(tag[range])
                } else if let range = Range(attributeMatch.range(at: 4), in: tag) {
                    value = String(tag[range])
                } else {
                    continue
                }
                attributes[tag[nameRange].lowercased()] = value
            }

            guard
                let relation = attributes["rel"]?.lowercased(),
                relation.contains("icon"),
                let href = attributes["href"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !href.isEmpty,
                let url = URL(string: href, relativeTo: baseURL)?.absoluteURL
            else {
                continue
            }

            var score = parseSizeAttribute(attributes["sizes"])
            if relation.contains("apple-touch-icon") { score += 64 }
            if relation.contains("mask-icon") { score -= 10_000 }
            candidates.append(Candidate(score: score, url: url))
        }

        var seen = Set<URL>()
        return candidates
            .sorted { $0.score > $1.score }
            .filter { seen.insert($0.url).inserted }
            .map(\.url)
    }

    private static func parseSizeAttribute(_ raw: String?) -> Int {
        guard let raw = raw?.lowercased() else { return 0 }
        if raw.contains("any") { return 1024 }

        var largest = 0
        for token in raw.split(whereSeparator: \Character.isWhitespace) {
            let dimensions = token.split(separator: "x")
            guard
                dimensions.count == 2,
                let width = Int(dimensions[0]),
                let height = Int(dimensions[1])
            else {
                continue
            }
            largest = max(largest, min(width, height))
        }
        return largest
    }
}
