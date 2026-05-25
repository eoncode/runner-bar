// RunnerBarUITests.swift
// RunnerBarUITests
import XCTest

// ⚠️ runner-bar uses NSPanel, NOT NSPopover.
// ❌ NEVER query app.popovers — always use app.windows.
// The app is LSUIElement=YES: no Dock icon, no app switcher, no visible windows.
// The status bar icon appears briefly during panel tests, then disappears on tearDown.
final class RunnerBarUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // ⚠️ --uitesting bypasses Keychain reads and API polling.
        // Without this the test run will silently hang waiting for a
        // Keychain approval prompt that never comes in CI.
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    // MARK: - Smoke tests

    func testAppLaunchesWithoutCrashing() {
        // LSUIElement app — no window on launch, but process must be alive
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    func testStatusBarItemExists() {
        let menuBar = XCUIApplication(bundleIdentifier: "com.apple.systemuiserver")
        let statusItem = menuBar.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
    }

    func testPanelOpensOnClick() {
        // NSPanel — query app.windows, NOT app.popovers
        let menuBar = XCUIApplication(bundleIdentifier: "com.apple.systemuiserver")
        let statusItem = menuBar.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        let panel = app.windows.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
    }

    func testPanelDismissesOnSecondClick() {
        let menuBar = XCUIApplication(bundleIdentifier: "com.apple.systemuiserver")
        let statusItem = menuBar.statusItems.firstMatch
        statusItem.click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 3))
        statusItem.click()
        XCTAssertFalse(app.windows.firstMatch.waitForExistence(timeout: 2))
    }
}
