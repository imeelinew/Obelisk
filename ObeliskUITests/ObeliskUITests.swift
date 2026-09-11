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
    func testSidebarToggleCollapsesAndRestoresSidebar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        let toggle = window.toolbars.buttons.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@", "sidebar")
        ).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), window.debugDescription)
        let sidebar = window.tables.firstMatch
        XCTAssertTrue(sidebar.exists)
        toggle.click()
        let collapsed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR hittable == false"), object: sidebar
        )
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed)
        toggle.click()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertTrue(sidebar.isHittable)
    }

    @MainActor
    func testClosingManagerWindowKeepsMenuBarAppRunning() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        window.buttons[XCUIIdentifierCloseWindow].click()

        XCTAssertFalse(window.waitForExistence(timeout: 2))
        XCTAssertNotEqual(app.state, .notRunning)
    }

    @MainActor
    func testDockActivationReopensClosedManagerWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertFalse(window.waitForExistence(timeout: 2))

        let dock = XCUIApplication(bundleIdentifier: "com.apple.dock")
        let dockIcons = dock.descendants(matching: .any).matching(identifier: "Obelisk")
        // A separately installed release can be pinned alongside the running
        // UI-test build. The latter is the final matching Dock item.
        let dockIcon = dockIcons.element(boundBy: max(0, dockIcons.count - 1))
        XCTAssertTrue(dockIcon.waitForExistence(timeout: 3))
        dockIcon.click()
        XCTAssertTrue(app.windows.element(boundBy: 0).waitForExistence(timeout: 8))
    }

    @MainActor
    func testStatusMenuTrackingDoesNotBlockDockActivation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.waitForExistence(timeout: 8))

        let statusMenuBar = app.menuBars.element(boundBy: 1)
        XCTAssertTrue(statusMenuBar.waitForExistence(timeout: 8))
        let statusItem = statusMenuBar.descendants(matching: .statusItem)
            .matching(NSPredicate(format: "label == %@", "Obelisk"))
            .firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3))
        statusItem.click()
        XCTAssertTrue(app.menuItems["退出"].waitForExistence(timeout: 3))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 3))

        let dock = XCUIApplication(bundleIdentifier: "com.apple.dock")
        let dockIcons = dock.descendants(matching: .any).matching(identifier: "Obelisk")
        let dockIcon = dockIcons.element(boundBy: max(0, dockIcons.count - 1))
        XCTAssertTrue(dockIcon.waitForExistence(timeout: 3))
        dockIcon.click()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3))
        XCTAssertTrue(window.isHittable)
    }

    @MainActor
    func testListContextMenuAcrossRowContents() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-bookmarkDisplayMode", "list", "-aiFeaturesEnabled", "NO"]
        app.launch()
        func addBookmark(title: String) {
            let add = app.buttons["添加"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 8))
            add.click()
            let titleField = app.textFields.element(boundBy: 0)
            XCTAssertTrue(titleField.waitForExistence(timeout: 3))
            titleField.click()
            titleField.typeKey("a", modifierFlags: .command)
            titleField.typeText(title)
            let url = app.textFields.element(boundBy: 1)
            url.click()
            url.typeKey("a", modifierFlags: .command)
            url.typeText("https://\(title.lowercased()).example")
            app.sheets.buttons["添加"].click()
        }
        addBookmark(title: "ContextMenuUITest")
        addBookmark(title: "OtherBookmark")

        let row = app.tables.tableRows.containing(.staticText, identifier: "ContextMenuUITest").firstMatch
        let otherRow = app.tables.tableRows.containing(.staticText, identifier: "OtherBookmark").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(otherRow.waitForExistence(timeout: 5), app.debugDescription)
        for point in [CGVector(dx: 0.15, dy: 0.3), CGVector(dx: 0.15, dy: 0.72),
                      CGVector(dx: 0.035, dy: 0.5), CGVector(dx: 0.85, dy: 0.5)] {
            for controlClick in [false, true] {
                otherRow.click()
                let target = row.coordinate(withNormalizedOffset: point)
                if controlClick {
                    XCUIElement.perform(withKeyModifiers: .control) { target.click() }
                } else {
                    target.rightClick()
                }
                let edit = app.menuItems["编辑"]
                XCTAssertTrue(edit.waitForExistence(timeout: 2), "Missing menu at \(point), control: \(controlClick)")
                edit.click()
                let editorTitle = app.sheets.textFields.element(boundBy: 0)
                XCTAssertTrue(editorTitle.waitForExistence(timeout: 3))
                XCTAssertEqual(editorTitle.value as? String, "ContextMenuUITest")
                app.sheets.buttons["取消"].click()
            }
        }
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
