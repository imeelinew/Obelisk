import AppKit
import Foundation

enum PrivateBrowserOpenResult {
    case opened
    case unsupportedBrowser
    case invalidURL
    case openFailed
}

enum PrivateBrowserOpener {
    private static let supportedChromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Canary",
        "com.brave.Browser",
        "org.chromium.Chromium",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera"
    ]

    private static let diaBundleID = "company.thebrowser.dia"

    static func openIncognito(urlString: String) -> PrivateBrowserOpenResult {
        guard let url = URL(string: urlString) else {
            return .invalidURL
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
              let bundleID = Bundle(url: appURL)?.bundleIdentifier
        else {
            return .unsupportedBrowser
        }

        if bundleID == diaBundleID {
            return openDiaIncognito(url: url)
        }

        guard supportedChromiumBundleIDs.contains(bundleID) else {
            return .unsupportedBrowser
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--incognito", url.absoluteString]

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                NSLog("Obelisk: failed to open private browser window: \(error.localizedDescription)")
            }
        }
        return .opened
    }

    private static func openDiaIncognito(url: URL) -> PrivateBrowserOpenResult {
        let source = """
        set targetURL to "\(appleScriptEscaped(url.absoluteString))"
        tell application id "\(diaBundleID)" to activate
        delay 0.2
        tell application "System Events"
            tell process "Dia"
                click menu item "New Incognito Window" of menu 1 of menu bar item "File" of menu bar 1
            end tell
        end tell
        delay 0.8
        tell application id "\(diaBundleID)"
            tell front window
                set URL of active tab to targetURL
            end tell
        end tell
        """

        guard let script = NSAppleScript(source: source) else {
            return .openFailed
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            NSLog("Obelisk: failed to open Dia incognito window: \(error)")
            return .openFailed
        }
        return .opened
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
