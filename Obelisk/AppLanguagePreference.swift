import AppKit
import Foundation
import ObeliskSync

enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case auto
    case zhHans = "zh-Hans"
    case en

    var id: String { rawValue }

    static let storageKey = "appLanguagePreference"

    /// Language names stay in their native form; only Auto follows the app locale.
    var pickerLabel: String {
        switch self {
        case .auto:
            return "自动检测".obeliskLocalized
        case .zhHans:
            return "简体中文"
        case .en:
            return "English"
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> AppLanguagePreference {
        let raw = defaults.string(forKey: storageKey) ?? AppLanguagePreference.auto.rawValue
        return AppLanguagePreference(rawValue: raw) ?? .auto
    }

    /// Apply `AppleLanguages` at launch so Bundle localization matches the preference.
    static func applyStoredPreference(in defaults: UserDefaults = .standard) {
        applyAppleLanguages(for: stored(in: defaults), in: defaults)
    }

    static func applyAppleLanguages(for preference: AppLanguagePreference, in defaults: UserDefaults = .standard) {
        switch preference {
        case .auto:
            defaults.removeObject(forKey: "AppleLanguages")
        case .zhHans:
            defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        case .en:
            defaults.set(["en"], forKey: "AppleLanguages")
        }
    }

    /// Persist preference for the next launch and prepare Bundle language override.
    static func persistForNextLaunch(_ preference: AppLanguagePreference, in defaults: UserDefaults = .standard) {
        defaults.set(preference.rawValue, forKey: storageKey)
        applyAppleLanguages(for: preference, in: defaults)
    }
}

enum AppRelauncher {
    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if error != nil {
                    // Fall back to `open -n` when Workspace refuses a second instance.
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    process.arguments = ["-n", Bundle.main.bundlePath]
                    try? process.run()
                }
                NSApp.terminate(nil)
            }
        }
    }
}

extension String {
    /// Resolves this Chinese source key via the app Bundle (honors `AppleLanguages` after relaunch).
    var obeliskLocalized: String {
        String(localized: String.LocalizationValue(self))
    }
}

func bookmarkCountSubtitle(_ count: Int) -> String {
    "\(count) \("个书签".obeliskLocalized)"
}

extension LLMModelSource {
    var localizedTitle: String {
        switch self {
        case .remote:
            return "远程 API".obeliskLocalized
        case .local:
            return "本地模型 (LM Studio)".obeliskLocalized
        }
    }
}
