import AppKit
import Foundation

/// Snapshot of the current tab in whatever browser is frontmost.
struct BrowserTab: Equatable {
    let url: String
    let title: String
}

enum BrowserCurrentTabFailure: Equatable {
    case noFrontmostApplication
    case unsupportedFrontmostApplication(String?)
    case noBrowserWindow
    case invalidURL
    case automationPermissionRequired
    case scriptFailed(Int?)
}

enum BrowserCurrentTabResult: Equatable {
    case success(BrowserTab)
    case failure(BrowserCurrentTabFailure)
}

/// Queries the frontmost browser for its active tab via AppleScript.
/// Returns a typed result so the hotkey path can fail closed instead of
/// accidentally falling back to unrelated state such as the pasteboard.
enum BrowserCurrentTab {
    static let noWindowSentinel = "__OBELISK_NO_BROWSER_WINDOW__"

    static func fetch() -> BrowserCurrentTabResult {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else {
            return .failure(.noFrontmostApplication)
        }

        guard let script = scriptSource(forBundleID: bundleID) else {
            return .failure(.unsupportedFrontmostApplication(bundleID))
        }

        return run(script)
    }

    /// Map known browser bundle IDs to their AppleScript dialect. Safari has
    /// its own (`current tab`, `name`); Chromium-family browsers all expose
    /// `active tab` + `title`.
    static func scriptSource(forBundleID bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return "\(noWindowSentinel)"
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
                if (count of windows) is 0 then return "\(noWindowSentinel)"
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

    private static func run(_ source: String) -> BrowserCurrentTabResult {
        guard let script = NSAppleScript(source: source) else {
            return .failure(.scriptFailed(nil))
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            NSLog("Obelisk: failed to read current browser tab: \(errorInfo)")
            return result(forAppleScriptError: errorInfo)
        }
        return parseScriptOutput(descriptor.stringValue)
    }

    static func result(forAppleScriptError errorInfo: NSDictionary) -> BrowserCurrentTabResult {
        let number = appleScriptErrorNumber(from: errorInfo)
        if number == -1743 {
            return .failure(.automationPermissionRequired)
        }
        return .failure(.scriptFailed(number))
    }

    static func parseScriptOutput(_ combined: String?) -> BrowserCurrentTabResult {
        guard let combined, !combined.isEmpty else {
            return .failure(.noBrowserWindow)
        }
        if combined == noWindowSentinel {
            return .failure(.noBrowserWindow)
        }

        // We return "URL\nTITLE" from the script. Splitting on the first
        // newline keeps page titles that themselves contain newlines intact.
        let parts = combined.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count >= 1 else {
            return .failure(.invalidURL)
        }
        let url = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = parts.count == 2
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        guard !url.isEmpty,
              let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            return .failure(.invalidURL)
        }

        return .success(BrowserTab(url: url, title: title))
    }

    private static func appleScriptErrorNumber(from errorInfo: NSDictionary) -> Int? {
        if let number = errorInfo["NSAppleScriptErrorNumber"] as? NSNumber {
            return number.intValue
        }
        return errorInfo["NSAppleScriptErrorNumber"] as? Int
    }
}
