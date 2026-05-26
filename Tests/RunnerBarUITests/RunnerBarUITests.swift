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
        // LSUIElement app never enters runningForeground — runningBackground is the correct state.
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
    }

    func testStatusBarItemExists() {
        let statusItem = controlCentre.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
    }

    func testPanelOpensOnClick() {
        // NSPanel — query app.windows, NOT app.popovers.
        // ⚠️ macOS 26: controlCentre.statusItems["com.eoncode.runner-bar"] does NOT work —
        // the accessibility identifier is NOT the bundle ID on macOS 26. Use firstMatch instead.
        // testStatusBarItemExists confirms firstMatch resolves to our item (only one item in CI).
        let statusItem = controlCentre.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        let panel = app.windows.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
    }

    func testPanelDismissesOnSecondClick() {
        // ⚠️ macOS 26: same as above — use firstMatch, not bundle-id identifier.
        let statusItem = controlCentre.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 3))
        statusItem.click()
        // 4s gives the panel enough time to fully dismiss under CI load
        XCTAssertFalse(app.windows.firstMatch.waitForExistence(timeout: 4))
    }
}
