import XCTest

final class ObeliskUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesManagerWindowInUITestingMode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        XCTAssertTrue(app.windows.element(boundBy: 0).waitForExistence(timeout: 8))
    }

    @MainActor
    func testManualArchiveCanBeRestoredWhenAutoArchiveIsDisabled() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting",
            "-autoArchiveIdleBookmarks", "NO"
        ]
        app.launch()

        let addButton = app.buttons["添加"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 8))
        addButton.click()

        let titleField = app.textFields.element(boundBy: 0)
        let urlField = app.textFields.element(boundBy: 1)
        XCTAssertTrue(titleField.waitForExistence(timeout: 3))
        titleField.click()
        titleField.typeText("ArchiveUITest")
        urlField.click()
        urlField.typeText("https://archive-ui-test.example")
        app.sheets.buttons["添加"].click()

        let bookmarkTitle = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "ArchiveUITest",
                "ArchiveUITest"
            )
        ).firstMatch
        XCTAssertTrue(bookmarkTitle.waitForExistence(timeout: 5))
        bookmarkTitle.rightClick()
        let archiveMenuItem = app.menuItems["归档"]
        XCTAssertTrue(archiveMenuItem.waitForExistence(timeout: 3))
        archiveMenuItem.click()

        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "归档")
        ).firstMatch.click()
        XCTAssertTrue(bookmarkTitle.waitForExistence(timeout: 5))

        bookmarkTitle.rightClick()
        let restoreMenuItem = app.menuItems["恢复到书签"]
        XCTAssertTrue(restoreMenuItem.waitForExistence(timeout: 3))
        restoreMenuItem.click()
        XCTAssertFalse(bookmarkTitle.waitForExistence(timeout: 2))
    }
}
