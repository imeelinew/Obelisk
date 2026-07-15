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

        for title in ["书签", "分组", "最近浏览", "更多", "搜索"] {
            XCTAssertTrue(tabBar.buttons[title].exists, "缺少 \(title) tab")
        }

        tabBar.buttons["分组"].tap()
        XCTAssertTrue(app.navigationBars["分组"].exists)

        tabBar.buttons["最近浏览"].tap()
        XCTAssertTrue(app.navigationBars["最近浏览"].exists)
        XCTAssertTrue(app.buttons["recent-browser-picker"].exists)
        XCTAssertTrue(app.staticTexts["没有最近浏览"].exists)

        tabBar.buttons["更多"].tap()
        XCTAssertTrue(app.navigationBars["更多"].exists)
        for title in ["隐藏书签", "归档", "Intelligence", "云同步", "设置", "关于 Obelisk"] {
            XCTAssertTrue(app.staticTexts[title].exists, "更多页面缺少 \(title)")
        }

        tabBar.buttons["搜索"].tap()
        XCTAssertTrue(app.navigationBars["搜索"].exists)
        XCTAssertTrue(app.searchFields["搜索书签"].waitForExistence(timeout: 2))
    }

}
