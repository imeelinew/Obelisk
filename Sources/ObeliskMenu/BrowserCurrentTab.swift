import AppKit
import Foundation

/// Snapshot of the current tab in whatever browser is frontmost.
struct BrowserTab {
    let url: String
    let title: String
}

/// Queries the frontmost browser for its active tab via AppleScript.
/// Returns nil when:
///   - the frontmost app isn't a recognized browser
///   - the user denied automation permission
///   - the browser has no open windows
///
/// Caller (Wave 5 hotkey path) falls back to `ClipboardURL` when fetch fails.
@MainActor
enum BrowserCurrentTab {

    static func fetch() -> BrowserTab? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else { return nil }

        guard let script = scriptSource(forBundleID: bundleID) else {
            return nil
        }

        guard let result = run(script) else {
            return nil
        }
        return result
    }

    /// Map known browser bundle IDs to their AppleScript dialect. Safari has
    /// its own (`current tab`, `name`); Chromium-family browsers all expose
    /// `active tab` + `title`.
    private static func scriptSource(forBundleID bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                set theURL to URL of current tab of front window
                set theTitle to name of current tab of front window
                return theURL & linefeed & theTitle
            end tell
            """

        case "com.google.Chrome",
             "com.google.Chrome.canary",
             "com.brave.Browser",
             "com.brave.Browser.beta",
             "com.brave.Browser.nightly",
             "com.microsoft.edgemac",
             "com.microsoft.edgemac.Beta",
             "com.microsoft.edgemac.Dev",
             "com.vivaldi.Vivaldi",
             "company.thebrowser.Browser",          // Arc
             "company.thebrowser.dia",              // Dia
             "com.operasoftware.Opera":
            return """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                set theURL to URL of active tab of front window
                set theTitle to title of active tab of front window
                return theURL & linefeed & theTitle
            end tell
            """

        default:
            // Firefox doesn't expose tab URLs without an extension — skip.
            return nil
        }
    }

    private static func run(_ source: String) -> BrowserTab? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)

        if errorInfo != nil {
            return nil
        }
        guard let combined = descriptor.stringValue, !combined.isEmpty else {
            return nil
        }

        // We return "URL\nTITLE" from the script. Splitting on the first
        // newline keeps page titles that themselves contain newlines intact.
        let parts = combined.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count >= 1 else { return nil }
        let url = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = parts.count == 2
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        guard !url.isEmpty,
              let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else { return nil }

        return BrowserTab(url: url, title: title)
    }
}
