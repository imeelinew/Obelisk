import Foundation

/// Fetches a page's `<title>` for the "auto-fill title" feature in the
/// bookmark editor. Lightweight: a single GET, regex match, basic entity
/// decoding. We deliberately avoid `NSAttributedString(html:)` because it
/// loads WebKit on the main thread.
@MainActor
final class PageMetadataFetcher {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.httpAdditionalHeaders = [
            "User-Agent": "UniBookmark/1.0",
            "Accept": "text/html,application/xhtml+xml"
        ]
        self.session = URLSession(configuration: config)
    }

    /// Returns the page's title, or nil if the URL can't be loaded or the
    /// HTML doesn't contain a usable `<title>`.
    func title(for url: URL) async -> String? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }

        // Try utf-8 first; fall back to charset declared by server, then
        // ISO-8859-1 which is the HTML default for legacy pages.
        let html = decode(data: data, response: http)
        guard let html else { return nil }

        return extractTitle(from: html)
    }

    private func decode(data: Data, response: HTTPURLResponse) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        let charset = (response.value(forHTTPHeaderField: "Content-Type") ?? "")
            .lowercased()
            .split(separator: ";")
            .compactMap { part -> String? in
                let kv = part.split(separator: "=", maxSplits: 1)
                guard kv.count == 2,
                      kv[0].trimmingCharacters(in: .whitespaces) == "charset" else { return nil }
                return kv[1].trimmingCharacters(in: .whitespaces)
            }
            .first
        if let charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: enc) { return s }
            }
        }
        return String(data: data, encoding: .isoLatin1)
    }

    private func extractTitle(from html: String) -> String? {
        let pattern = #"(?is)<title\b[^>]*>(.*?)</title>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: html,
                range: NSRange(html.startIndex..<html.endIndex, in: html)
              ),
              let titleRange = Range(match.range(at: 1), in: html)
        else { return nil }

        let raw = String(html[titleRange])
        let decoded = decodeHTMLEntities(raw)
        let normalized = decoded
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func decodeHTMLEntities(_ s: String) -> String {
        var result = s
        // Common named entities that frequently show up in titles.
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
            ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&hellip;", "…"), ("&laquo;", "«"), ("&raquo;", "»"),
            ("&copy;", "©"), ("&reg;", "®"), ("&trade;", "™")
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        // Numeric entities (decimal & hex). Run hex first because the regex
        // for decimal would otherwise eat the leading "x" pattern incorrectly.
        result = replaceNumericEntities(in: result, pattern: #"&#x([0-9a-fA-F]+);"#, radix: 16)
        result = replaceNumericEntities(in: result, pattern: #"&#([0-9]+);"#, radix: 10)
        return result
    }

    private func replaceNumericEntities(in input: String, pattern: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let nsInput = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
        guard !matches.isEmpty else { return input }

        var result = ""
        var cursor = 0
        for match in matches {
            let full = match.range
            if full.location > cursor {
                result += nsInput.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            let codePointStr = nsInput.substring(with: match.range(at: 1))
            if let value = UInt32(codePointStr, radix: radix), let scalar = Unicode.Scalar(value) {
                result.unicodeScalars.append(scalar)
            } else {
                result += nsInput.substring(with: full)
            }
            cursor = full.location + full.length
        }
        if cursor < nsInput.length {
            result += nsInput.substring(with: NSRange(location: cursor, length: nsInput.length - cursor))
        }
        return result
    }
}
