// RunnerBarUITests.swift
// RunnerBarUITests
import XCTest

// ⚠️ runner-bar uses NSPanel, NOT NSPopover.
// ❌ NEVER query app.popovers — always use app.windows.
// The app is LSUIElement=YES: no Dock icon, no app switcher, no visible windows.
// The status bar icon appears briefly during panel interaction tests, then disappears on tearDown.
final class RunnerBarUITests: XCTestCase {

    var app: XCUIApplication!

    // macOS 13+ routes status bar items through Control Centre, not systemuiserver.
    // ❌ NEVER use "com.apple.systemuiserver" — it will not find the status item on modern macOS.
    private let controlCentre = XCUIApplication(bundleIdentifier: "com.apple.controlcenter")

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
        let statusItem = controlCentre.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
    }

    func testPanelOpensOnClick() {
        // NSPanel — query app.windows, NOT app.popovers
        let statusItem = controlCentre.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        let panel = app.windows.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
    }

    func testPanelDismissesOnSecondClick() {
        let statusItem = controlCentre.statusItems.firstMatch
        statusItem.click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 3))
        statusItem.click()
        // 4s gives the panel enough time to fully dismiss under CI load
        XCTAssertFalse(app.windows.firstMatch.waitForExistence(timeout: 4))
    }
}
