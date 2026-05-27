import AppKit
import Foundation

enum ClipboardURL {
    /// Returns a normalized http(s) URL string from the general pasteboard, or nil.
    static func normalizedHTTPURL() -> String? {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              parsed.host?.isEmpty == false
        else { return nil }
        return trimmed
    }
}
