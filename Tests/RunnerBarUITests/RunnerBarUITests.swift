// RunnerBarUITests.swift
// RunnerBarUITests
//
// UI tests for RunnerBar using real mouse interaction.
// Runs on the self-hosted runner via xcodebuild.
//
// Design:
//   • AppDelegate sets .regular activation policy + activate() when UI_TESTING is set.
//
// ⚠️ app.windows does NOT enumerate NSPanel with [.borderless, .nonactivatingPanel].
//    ❌ NEVER use app.windows. Use app.staticTexts / app.buttons directly.
//
// ⚠️ Text("Settings") is nested inside a Button — NOT a standalone staticText.
//    ❌ NEVER assert app.staticTexts["Settings"].
//    ✓ Use app.staticTexts["Active local runners"] as proof Settings is open.
//
// ⚠️ isHittable is always false for buttons inside .nonactivatingPanel.
//    ❌ NEVER wait for isHittable.
//
// ⚠️ .click() on panel elements misfires due to Quartz/HIServices Y-axis flip.
//    ❌ NEVER call .click() directly.
//    ✓ Always use .coordinate(withNormalizedOffset: CGVector(dx:0.5, dy:0.5)).click()
//
// ⚠️ AddMode Picker segments ("Add new", "Add pre-existing") and ScopeType
//    Picker segments ("Organisation", "Repository") are NOT AX buttons.
//    They render as radioButton children inside a radioGroup.
//    ❌ NEVER assert app.buttons["Add new"] etc.
//    ✓ Assert staticTexts["Add runner"] / staticTexts["Add remote scope"] as arrival proof.
//
// ⚠️ The two Add buttons both have identifier 'plus' and label 'Add'.
//    Disambiguate by index: app.buttons.matching(identifier:"plus").element(boundBy: N)

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

    /// Opens the panel and waits for the WORKFLOWS header.
    private func openPanel() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "Status item must exist")
        statusItem.click()
        XCTAssertTrue(
            app.staticTexts["WORKFLOWS"].waitForExistence(timeout: 5),
            "Main panel must show WORKFLOWS after status item click"
        )
    }

    /// Waits for existence, then clicks centre via normalised-offset coordinate.
    /// Avoids the Quartz/HIServices Y-axis flip that direct .click() suffers on
    /// borderless nonActivatingPanels.
    private func tapButton(_ element: XCUIElement, timeout: TimeInterval = 5) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Element must exist: \(element.debugDescription)")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    // MARK: - Settings navigation

    /// Full settings flow:
    /// open panel → Settings → verify sections →
    /// Add Runner sheet (open + cancel) →
    /// Add Scope sheet (open + cancel) →
    /// back to main.
    func testSettingsNavigationFlow() {
        openPanel()

        // ── 1. Open Settings ──────────────────────────────────────────
        tapButton(app.buttons["Settings"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 5),
                      "Active local runners section")
        XCTAssertTrue(app.staticTexts["Remote runner scopes"].exists, "Remote runner scopes")
        XCTAssertTrue(app.staticTexts["Notifications"].exists, "Notifications")
        XCTAssertTrue(app.staticTexts["General"].exists, "General")
        XCTAssertTrue(app.staticTexts["Account"].exists, "Account")
        XCTAssertTrue(app.staticTexts["About"].exists, "About")

        // ── 2. Add Runner sheet ───────────────────────────────────────
        // First 'plus' button (boundBy:0) = Add runner.
        // Second 'plus' button (boundBy:1) = Add scope.
        // Do NOT assert Picker segment labels as buttons — they are radioButtons.
        tapButton(app.buttons.matching(identifier: "plus").element(boundBy: 0))
        XCTAssertTrue(app.staticTexts["Add runner"].waitForExistence(timeout: 3),
                      "Add Runner sheet title")
        tapButton(app.buttons["Cancel"])
        XCTAssertTrue(app.staticTexts["Active local runners"].waitForExistence(timeout: 3),
                      "Back in Settings after Cancel")

        // ── 3. Add Scope sheet ────────────────────────────────────────
        tapButton(app.buttons.matching(identifier: "plus").element(boundBy: 1))
        XCTAssertTrue(app.staticTexts["Add remote scope"].waitForExistence(timeout: 3),
                      "Add Scope sheet title")
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
