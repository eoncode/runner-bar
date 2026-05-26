// RunnerBarUITests.swift
// RunnerBarUITests
//
// Verified AX tree from live run (2026-05-26):
//   Settings view buttons:
//     Button, label: 'Settings'                         ← back button
//     Button, identifier: 'plus', label: 'Add'          ← Add runner (first plus)
//     Button, identifier: 'arrow.clockwise', label: 'Refresh'
//     Button, label: 'MacBookPro, ...'
//     Button, label: 'psw-org-runner, ...'
//     Button, label: 'run-bar-runner-1, ...'
//     Button, identifier: 'plus', label: 'Add'          ← Add scope (second plus)
//     Button, label: 'Sign in with GitHub'
//
// ⚠️ The two Add buttons have identical label 'Add' and identifier 'plus'.
//    We disambiguate by index: buttons.matching(identifier:"plus").element(boundBy: 0/1)
//
// ⚠️ app.windows does NOT enumerate NSPanel — use app.staticTexts/buttons directly.
// ⚠️ Text("Settings") is inside a Button — never assert app.staticTexts["Settings"].
// ⚠️ Do NOT call app.activate() after opening panel — it dismisses the panel.

import XCTest

final class RunnerBarUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.eonist.runnerbar")
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    // MARK: - Helpers

    private func openPanel() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "Status item must exist")
        statusItem.click()
        XCTAssertTrue(
            app.staticTexts["WORKFLOWS"].waitForExistence(timeout: 5),
            "Main panel must show WORKFLOWS after status item click"
        )
    }

    /// Click an element by waiting for existence then using coordinate-based click
    /// to guarantee the event fires at the element's current screen-space centre.
    private func tapButton(_ element: XCUIElement, timeout: TimeInterval = 5) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Element must exist: \(element.debugDescription)")
        // coordinate click re-resolves frame at event time — avoids stale position
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    // MARK: - Settings navigation

    func testSettingsNavigationFlow() {
        openPanel()

        // ── 1. Open Settings ──────────────────────────────────────────
        tapButton(app.buttons["Settings"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 5),
                      "Active local runners section must appear")
        XCTAssertTrue(app.staticTexts["Remote runner scopes"].exists, "Remote runner scopes")
        XCTAssertTrue(app.staticTexts["Notifications"].exists, "Notifications")
        XCTAssertTrue(app.staticTexts["General"].exists, "General")
        XCTAssertTrue(app.staticTexts["Account"].exists, "Account")
        XCTAssertTrue(app.staticTexts["About"].exists, "About")

        // ── 2. Add Runner sheet ───────────────────────────────────────
        // First 'plus' button = Add runner (above the runners list)
        let addRunnerBtn = app.buttons.matching(identifier: "plus").element(boundBy: 0)
        tapButton(addRunnerBtn)
        XCTAssertTrue(app.staticTexts["Add runner"].waitForExistence(timeout: 3),
                      "Add Runner sheet title")
        XCTAssertTrue(app.buttons["Add new"].exists, "Add new button")
        XCTAssertTrue(app.buttons["Add pre-existing"].exists, "Add pre-existing button")
        tapButton(app.buttons["Cancel"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 3),
                      "Back in Settings after Cancel")

        // ── 3. Add Scope sheet ────────────────────────────────────────
        // Second 'plus' button = Add scope (above the scopes list)
        let addScopeBtn = app.buttons.matching(identifier: "plus").element(boundBy: 1)
        tapButton(addScopeBtn)
        XCTAssertTrue(app.staticTexts["Add remote scope"].waitForExistence(timeout: 3),
                      "Add Scope sheet title")
        XCTAssertTrue(app.buttons["Organisation"].exists, "Organisation button")
        XCTAssertTrue(app.buttons["Repository"].exists, "Repository button")
        tapButton(app.buttons["Cancel"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 3),
                      "Back in Settings after Cancel")

        // ── 4. Back to main ───────────────────────────────────────────
        tapButton(app.buttons["Settings"])
        XCTAssertTrue(
            app.staticTexts["WORKFLOWS"].waitForExistence(timeout: 5),
            "WORKFLOWS must reappear after back navigation"
        )
        XCTAssertFalse(
            app.staticTexts["Active local runners"].exists,
            "Settings content must not be visible on main view"
        )
    }
}
