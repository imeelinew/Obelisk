import XCTest

final class Obelisk_iOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testApprovedMainNavigation() {
        let app = XCUIApplication()
        app.launchEnvironment["OBELISK_HOME"] = NSTemporaryDirectory()
            + "Obelisk-iOSUITests-\(UUID().uuidString)"
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        for title in ["书签", "分组", "最近浏览", "搜索"] {
            XCTAssertTrue(tabBar.buttons[title].exists, "缺少 \(title) tab")
        }

        tabBar.buttons["分组"].tap()
        XCTAssertTrue(app.navigationBars["分组"].exists)

        tabBar.buttons["最近浏览"].tap()
        XCTAssertTrue(app.navigationBars["最近浏览"].exists)

        tabBar.buttons["搜索"].tap()
        XCTAssertTrue(app.navigationBars["搜索"].exists)
        XCTAssertTrue(app.searchFields["搜索书签"].waitForExistence(timeout: 2))
    }
}
