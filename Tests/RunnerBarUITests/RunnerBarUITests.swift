import XCTest

final class RunnerBarUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.eoncode.runner-bar")
        app.launch()
        // Allow the status item time to appear in the menu bar
        Thread.sleep(forTimeInterval: 1.0)
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Helpers

    /// Returns the RunnerBar status item by querying the running app's own
    /// status items, avoiding accidental matches on system extras (e.g. Battery).
    private var runnerBarStatusItem: XCUIElement {
        // The status bar items owned by our app process
        let statusItems = app.statusItems
        // Prefer an item labelled "RunnerBar"; fall back to the first owned item
        if statusItems["RunnerBar"].exists {
            return statusItems["RunnerBar"]
        }
        return statusItems.firstMatch
    }

    // MARK: - Tests

    func testStatusBarItemExists() throws {
        XCTAssertTrue(
            runnerBarStatusItem.waitForExistence(timeout: 5),
            "RunnerBar status item should exist in the menu bar"
        )
    }

    func testAppLaunchesWithoutCrashing() throws {
        // Verify the app launched and is still running
        XCTAssertEqual(
            app.state,
            .runningBackground,
            "RunnerBar should be running (as a background/menu-bar app) after launch"
        )
    }

    func testPanelOpensOnClick() throws {
        let statusItem = runnerBarStatusItem
        XCTAssertTrue(
            statusItem.waitForExistence(timeout: 5),
            "RunnerBar status item must exist before clicking"
        )
        statusItem.click()
        // Give the panel time to animate open
        Thread.sleep(forTimeInterval: 0.5)
        // Panel window should now be visible
        XCTAssertTrue(
            app.windows.firstMatch.exists,
            "A window should appear after clicking the status item"
        )
    }

    func testPanelDismissesOnSecondClick() throws {
        let statusItem = runnerBarStatusItem
        XCTAssertTrue(
            statusItem.waitForExistence(timeout: 5),
            "RunnerBar status item must exist before clicking"
        )
        // First click opens
        statusItem.click()
        Thread.sleep(forTimeInterval: 0.5)
        // Second click closes
        statusItem.click()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(
            app.windows.firstMatch.exists,
            "Panel should be dismissed after a second click on the status item"
        )
    }
}
