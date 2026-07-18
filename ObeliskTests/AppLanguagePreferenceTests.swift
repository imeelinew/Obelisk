import XCTest
@testable import Obelisk

final class AppLanguagePreferenceTests: XCTestCase {
    func testStoredPreferenceDefaultsToAuto() {
        let suiteName = "Obelisk.AppLanguagePreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(AppLanguagePreference.stored(in: defaults), .auto)
    }

    func testStoredPreferenceReadsExplicitValue() {
        let suiteName = "Obelisk.AppLanguagePreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppLanguagePreference.en.rawValue, forKey: AppLanguagePreference.storageKey)
        XCTAssertEqual(AppLanguagePreference.stored(in: defaults), .en)

        defaults.set(AppLanguagePreference.zhHans.rawValue, forKey: AppLanguagePreference.storageKey)
        XCTAssertEqual(AppLanguagePreference.stored(in: defaults), .zhHans)
    }

    func testPersistForNextLaunchWritesPreference() {
        let suiteName = "Obelisk.AppLanguagePreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppLanguagePreference.persistForNextLaunch(.en, in: defaults)
        XCTAssertEqual(AppLanguagePreference.stored(in: defaults), .en)

        AppLanguagePreference.persistForNextLaunch(.auto, in: defaults)
        XCTAssertEqual(AppLanguagePreference.stored(in: defaults), .auto)
    }
}
