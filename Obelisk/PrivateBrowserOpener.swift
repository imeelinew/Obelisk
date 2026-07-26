import AppKit
import ApplicationServices
import Foundation

enum BrowserAutomationPermission: Equatable {
    case accessibility
    case appleEvents
}

enum PrivateBrowserOpenResult: Equatable {
    case opened
    case unsupportedBrowser
    case invalidURL
    case openFailed
    case automationPermissionRequired(BrowserAutomationPermission)
}

enum PrivateBrowserOpenStrategy: Equatable {
    case diaAppleScript
    case chromeAppleScript
    case chromiumLaunchArguments
    case unsupported
}

enum PrivateBrowserOpener {
    private static let chromeBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary"
    ]

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
    private static let diaIncognitoWindowIDKey = "diaIncognitoWindowID"
    private static let chromeIncognitoWindowIDKeyPrefix = "chromeIncognitoWindowID."

    static func openIncognito(urlString: String) -> PrivateBrowserOpenResult {
        guard let url = URL(string: urlString) else {
            return .invalidURL
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
              let bundleID = Bundle(url: appURL)?.bundleIdentifier
        else {
            return .unsupportedBrowser
        }

        switch strategy(forBundleID: bundleID) {
        case .diaAppleScript:
            return openDiaIncognito(url: url)
        case .chromeAppleScript:
            return openChromeIncognito(url: url, bundleID: bundleID)
        case .chromiumLaunchArguments:
            return openChromiumIncognito(url: url, appURL: appURL)
        case .unsupported:
            return .unsupportedBrowser
        }
    }

    static func strategy(forBundleID bundleID: String) -> PrivateBrowserOpenStrategy {
        if bundleID == diaBundleID {
            return .diaAppleScript
        }
        if chromeBundleIDs.contains(bundleID) {
            return .chromeAppleScript
        }
        if supportedChromiumBundleIDs.contains(bundleID) {
            return .chromiumLaunchArguments
        }
        return .unsupported
    }

    private static func openChromiumIncognito(
        url: URL,
        appURL: URL
    ) -> PrivateBrowserOpenResult {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--incognito", url.absoluteString]

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                NSLog("Obelisk: failed to open private browser window: \(error.localizedDescription)")
            }
        }
        return .opened
    }

    private static func openChromeIncognito(
        url: URL,
        bundleID: String
    ) -> PrivateBrowserOpenResult {
        let windowIDKey = chromeIncognitoWindowIDKeyPrefix + bundleID
        guard let script = NSAppleScript(source: chromeAppleScriptSource(
            url: url,
            bundleID: bundleID,
            savedWindowID: UserDefaults.standard.string(forKey: windowIDKey) ?? ""
        )) else {
            return .openFailed
        }

        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            NSLog("Obelisk: failed to open Chrome incognito window: \(error)")
            return result(forAppleScriptError: error)
        }
        guard let windowID = chromeIncognitoWindowID(fromAppleScriptOutput: output.stringValue ?? "") else {
            NSLog("Obelisk: Chrome did not confirm an incognito window")
            return .openFailed
        }
        UserDefaults.standard.set(windowID, forKey: windowIDKey)
        return .opened
    }

    static func chromeAppleScriptSource(
        url: URL,
        bundleID: String,
        savedWindowID: String
    ) -> String {
        """
        set targetURL to "\(appleScriptEscaped(url.absoluteString))"
        set savedWindowID to "\(appleScriptEscaped(savedWindowID))"
        tell application id "\(appleScriptEscaped(bundleID))"
            if savedWindowID is not "" then
                try
                    set privateWindow to first window whose id is savedWindowID
                    if (mode of privateWindow as text) is "incognito" then
                        tell privateWindow
                            make new tab at end of tabs with properties {URL:targetURL}
                            set active tab index to count of tabs
                            set visible to true
                        end tell
                        activate
                        return "incognito" & linefeed & (id of privateWindow as text)
                    end if
                end try
            end if

            set privateWindow to make new window with properties {mode:"incognito"}
            set URL of active tab of privateWindow to targetURL
            set visible of privateWindow to true
            activate
            return (mode of privateWindow as text) & linefeed & (id of privateWindow as text)
        end tell
        """
    }

    static func chromeIncognitoWindowID(fromAppleScriptOutput output: String) -> String? {
        let components = output.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              components[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "incognito"
        else {
            return nil
        }
        let windowID = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return windowID.isEmpty ? nil : windowID
    }

    private static func openDiaIncognito(url: URL) -> PrivateBrowserOpenResult {
        guard accessibilityPermissionIsGranted(prompt: true) else {
            return .automationPermissionRequired(.accessibility)
        }

        let source = """
        set targetURL to "\(appleScriptEscaped(url.absoluteString))"
        set savedWindowID to "\(appleScriptEscaped(UserDefaults.standard.string(forKey: diaIncognitoWindowIDKey) ?? ""))"
        tell application id "\(diaBundleID)" to activate
        delay 0.15

        tell application id "\(diaBundleID)"
            if savedWindowID is not "" then
                try
                    tell (first window whose id is savedWindowID)
                        make new tab at end of tabs with properties {URL:targetURL}
                        set visible to true
                    end tell
                    return savedWindowID
                end try
            end if
        end tell

        tell application "System Events"
            tell process "Dia"
                click menu item "New Incognito Window" of menu 1 of menu bar item "File" of menu bar 1
            end tell
        end tell
        delay 0.8

        tell application id "\(diaBundleID)"
            tell front window
                set URL of active tab to targetURL
                set visible to true
                return id as text
            end tell
        end tell
        """

        guard let script = NSAppleScript(source: source) else {
            return .openFailed
        }

        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            NSLog("Obelisk: failed to open Dia incognito window: \(error)")
            return result(forAppleScriptError: error)
        }
        let windowID = (output.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !windowID.isEmpty {
            UserDefaults.standard.set(windowID, forKey: diaIncognitoWindowIDKey)
        }
        return .opened
    }

    static func result(forAppleScriptError errorInfo: NSDictionary) -> PrivateBrowserOpenResult {
        let number = appleScriptErrorNumber(from: errorInfo)
        if number == -1743 {
            return .automationPermissionRequired(.appleEvents)
        }
        return .openFailed
    }

    private static func accessibilityPermissionIsGranted(prompt: Bool) -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func appleScriptErrorNumber(from errorInfo: NSDictionary) -> Int? {
        if let number = errorInfo["NSAppleScriptErrorNumber"] as? NSNumber {
            return number.intValue
        }
        return errorInfo["NSAppleScriptErrorNumber"] as? Int
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\u{2028}", with: " ")
            .replacingOccurrences(of: "\u{2029}", with: " ")
        return sanitized
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
