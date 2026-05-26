# UI Test CI — What Doesn't Work (and What Does)

Running log of the `feature/936-xcodegen-uitest-setup` branch.  
Update this file every time something new breaks or works. Do **not** delete old entries.

---

## ✅ What Finally Worked (2026-05-26)

**Passing config:**
- `type: bundle.ui-testing` in project.yml — no `TEST_HOST`, no `BUNDLE_LOADER`
- `CODE_SIGN_IDENTITY: "-"` + `CODE_SIGNING_REQUIRED: NO` + `AD_HOC_CODE_SIGNING_ALLOWED: YES`
- `GENERATE_INFOPLIST_FILE: YES` on `RunnerBarUITests`
- `XCUIApplication(bundleIdentifier: "dev.eonist.runnerbar")` — NOT default init
- `app.wait(for: .runningBackground, timeout:)` — NOT `.runningForeground`
- **No `dependencies` on `RunnerBar` in the `RunnerBarUITests` target** — prevents Xcode 26 from auto-injecting `XCTTargetAppPath`
- **No `testTargetApp` in scheme** — same reason
- **`UI_TESTING` as `environmentVariables`** in scheme, NOT `commandLineArguments`
- **Dedicated `RunnerBarUITests` scheme** used for `xcodebuild test`
- **App built in a separate step** before `xcodebuild test`; both steps share `-derivedDataPath`
- **Only `pull_request` trigger** in `ui-tests.yml` — not `push` (avoids duplicate runs)
- `xcodebuild test -scheme RunnerBarUITests -only-testing:RunnerBarUITests` on self-hosted runner with GUI session
- **`OPEN_PANEL_ON_LAUNCH` sets panel level to `.floating`** and uses `setFrameOrigin + orderFront` — see lessons below

---

## project.yml — XcodeGen Configuration

### ❌ `TEST_HOST` + `BUNDLE_LOADER` on a `bundle.ui-testing` target
**Error:** `Invalid configuration: RunnerBarUITests sets both USES_XCTRUNNER and either TEST_HOST or RUNTIME_TEST_HOST`  
**Why:** `type: bundle.ui-testing` automatically sets `USES_XCTRUNNER=YES`. This flag is mutually exclusive with `TEST_HOST`/`BUNDLE_LOADER`.  
**Fix:** Remove `TEST_HOST` and `BUNDLE_LOADER` entirely from the `RunnerBarUITests` settings block.  
**Rule:** Never mix `bundle.ui-testing` with `TEST_HOST`/`BUNDLE_LOADER`.

---

### ❌ `CODE_SIGN_IDENTITY: ""` (empty string) on UI test bundle
**Error:** Signing error — empty identity rejected for UI test bundles.  
**Fix:** Use `CODE_SIGN_IDENTITY: "-"` (ad-hoc), plus `CODE_SIGNING_REQUIRED: NO` and `AD_HOC_CODE_SIGNING_ALLOWED: YES`.

---

### ❌ Mismatched package key in `project.yml`
**Error:** XcodeGen fails to resolve the local SPM package.  
**Why:** The `packages:` key name must match `Package.swift`'s `name:` field exactly.  
**Fix:** Use `name: RunnerBar` in Package.swift and `packages: RunnerBar: path: .` in project.yml.

---

### ❌ Missing `GENERATE_INFOPLIST_FILE: YES` on `RunnerBarUITests`
**Error:** Build fails — no Info.plist for the test bundle.  
**Fix:** Add `GENERATE_INFOPLIST_FILE: YES` to `RunnerBarUITests` settings.

---

### ❌ `RunnerBarUITests` not wired into the scheme's test action
**Error:** `xcodebuild test -only-testing:RunnerBarUITests` finds nothing to run.  
**Fix:** The `schemes.RunnerBarUITests.test.targets` list must explicitly include `RunnerBarUITests`.

---

### ❌ Using the `RunnerBar` app scheme for `xcodebuild test` (Xcode 26)
**Error:** `The bundle identifier for RunnerBar couldn't be read. No such file or directory: ".../Debug/RunnerBar"`  
**Why:** Running UI tests via the app's own scheme causes Xcode 26 to auto-populate `XCTTargetAppPath` internally with `.app` stripped.  
**Fix:** Use a dedicated `RunnerBarUITests` scheme with no `testTargetApp` key.

---

### ❌ `dependencies: - target: RunnerBar` on `RunnerBarUITests` target (Xcode 26)
**Error:** `The bundle identifier for RunnerBar couldn't be read. No such file or directory: ".../Debug/RunnerBar"` — persists even with a dedicated scheme.  
**Why:** On Xcode 26, a target-level dependency from a `bundle.ui-testing` target to an app target triggers auto-injection of `XCTTargetAppPath` regardless of scheme configuration. Xcode sees "this UI test bundle depends on this app" and wires the path internally — then strips `.app` from it.  
**Fix:** Remove `dependencies` from `RunnerBarUITests` entirely. Build the app in a **separate `xcodebuild build` step** in the CI workflow first, then run `xcodebuild test`. Both steps share `-derivedDataPath` so the already-built `.app` is found by Launch Services.  
**Rule:** On Xcode 26, `bundle.ui-testing` targets must have **zero target dependencies** on the app. Build separately, test separately.

---

### ❌ `UI_TESTING` in scheme `commandLineArguments` instead of `environmentVariables`
**Error:** `ProcessInfo.processInfo.environment["UI_TESTING"]` is always `nil`.  
**Why:** `commandLineArguments` become `argv[]` entries, not environment variables.  
**Fix:** Move `UI_TESTING` to `environmentVariables` in the scheme's `test` block.

---

### ❌ `XCTTargetAppPath` in scheme `environmentVariables` (Xcode 26)
**Error:** `The bundle identifier for RunnerBar couldn't be read.`  
**Why:** Xcode 26 strips `.app` from this path value.  
**Fix:** Do not set `XCTTargetAppPath` at all. Use `XCUIApplication(bundleIdentifier:)` + Launch Services.

---

### ❌ `push` + `pull_request` triggers both set in `ui-tests.yml`
**Problem:** Every push to the feature branch fires two runs: one for the push event and one for the PR event. Wastes runner time and shows 2 failing checks instead of 1.  
**Fix:** Use only `pull_request` trigger. A PR event covers the branch head automatically.  
**Rule:** For self-hosted runner jobs on feature branches with an open PR, `pull_request` alone is sufficient.

---

## XCUIApplication — Test Code

### ❌ `XCUIApplication()` default init with LSUIElement app on Xcode 26
**Error:** App resolves wrong path; test fails to launch.  
**Fix:** Always use `XCUIApplication(bundleIdentifier: "dev.eonist.runnerbar")`.

---

### ❌ `app.wait(for: .runningForeground, timeout:)` on a `LSUIElement` menu bar agent
**Error:** Test always times out.  
**Why:** `LSUIElement = true` apps are background agents; they never become `.runningForeground`.  
**Fix:** Use `.runningBackground` instead.

---

### ❌ `app.popovers` for an `NSPanel`-based app
**Error:** `app.popovers.firstMatch` never exists.  
**Fix:** Use `app.windows` instead.

---

### ❌ Synthesising click/mouse events in CI on a shared active desktop
**Problem:** `XCUIApplication.click()` physically moves the mouse cursor and steals focus.  
**Fix:** Keep all CI tests READ-ONLY. Use `OPEN_PANEL_ON_LAUNCH=1` env var to open the panel.

---

### ❌ `openPanel()` called from `OPEN_PANEL_ON_LAUNCH` branch — panel off-screen (PR #947, 2 CI runs)
**Error:** `XCTAssertTrue failed - Panel (NSPanel) should appear in the AX tree after auto-open`  
**Root cause:** `openPanel()` positions relative to `statusItem.button?.window.frame`, which is nil/zero in a pure `XCUIApplication` launch. Panel lands at `{0, 0}` — off-screen on macOS.  
**Fix (983b57a):** Replace with `panel.setFrameOrigin(visibleFrame-based) + panel.orderFront(nil)`.  
**Rule:** Never call `openPanel()` from `OPEN_PANEL_ON_LAUNCH` branch.

---

### ❌ `NSPanel` at `.popUpMenu` level invisible to XCTest AX tree — `app.windows` always empty (PR #947, 3f2eea4)
**Error:** `XCTAssertTrue failed - Panel (NSPanel) should appear in the AX tree after auto-open` — persists even after switching from `openPanel()` to `setFrameOrigin+orderFront`.  
**Confirmed:** `testAppLaunchesWithoutCrashing` ✅ and `testStatusBarItemExists` ✅ still pass. Panel IS on-screen — `orderFront` is called and succeeds.  
**Root cause:** The XCTest AX server queries the target app's window list via the Accessibility API. `NSPanel` windows at `.popUpMenu` level are treated as **system overlay UI** and excluded from the AX window list returned to external processes. This is a macOS AX architectural limitation: only windows at `.normal`, `.floating`, or below are surfaced as `AXWindow` elements in `app.windows`. `.popUpMenu` panels are invisible to XCTest regardless of position.  
**Fix (committed in [3f2eea4](https://github.com/eoncode/runner-bar/commit/3f2eea41ede7122f27d471123b4837e4f5893795)):**  
In `AppDelegate+PanelSetup.swift`, lower the panel level during UI tests:
```swift
if ProcessInfo.processInfo.environment["OPEN_PANEL_ON_LAUNCH"] != nil {
    newPanel.level = .floating   // XCTest AX can see .floating; not .popUpMenu
} else {
    newPanel.level = .popUpMenu  // Production: stay above all normal windows
}
```
**Rule:** For UI tests that need to query the panel via `app.windows`, set `panel.level = .floating`. Production code keeps `.popUpMenu`. Never use `.popUpMenu` and expect XCTest to see the window.

---

### ✅ How to test the panel without clicking — `OPEN_PANEL_ON_LAUNCH` (final working pattern)
**Solution (after 3f2eea4):** In `AppDelegate+PanelSetup.swift`:
```swift
// Level must be .floating for XCTest AX visibility (not .popUpMenu)
if ProcessInfo.processInfo.environment["OPEN_PANEL_ON_LAUNCH"] != nil {
    newPanel.level = .floating
} else {
    newPanel.level = .popUpMenu
}
// ... then after panel = newPanel ...
if ProcessInfo.processInfo.environment["OPEN_PANEL_ON_LAUNCH"] != nil {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        guard let self, let p = self.panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let x = screen.visibleFrame.maxX - p.frame.width - 20
        let y = screen.visibleFrame.maxY - p.frame.height - 20
        p.setFrameOrigin(NSPoint(x: x, y: y))
        p.orderFront(nil)
    }
}
```
In test: `app.launchEnvironment["OPEN_PANEL_ON_LAUNCH"] = "1"` + `panel.waitForExistence(timeout: 10)`.

---

## CI Workflow — `ui-tests.yml`

### ❌ `xcpretty` on macOS arm64 (system Ruby 2.6)
**Error:** `xcpretty` gem install fails on Apple Silicon.  
**Fix:** Drop `xcpretty`. Use raw `xcodebuild` output.

---

### ❌ Runner installed as a system `LaunchDaemon`
**Error:** No GUI session → XCUIApplication can't launch.  
**Fix:** Install as user `LaunchAgent`:
```bash
sudo ./svc.sh uninstall && ./svc.sh install && ./svc.sh start
```

---

### ❌ `xcode-select` pointing at CommandLineTools
**Fix:**
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

---

## General Rules (Don't Forget)

| Rule | Detail |
|------|--------|
| **Never use CI as a scratch pad** | Validate `xcodegen generate && xcodebuild build/test` locally before committing. |
| **`bundle.ui-testing` ≠ `bundle.unit-test`** | No `TEST_HOST`, no `BUNDLE_LOADER`, uses XCTRunner. |
| **Zero target dependencies on app** | `RunnerBarUITests` must NOT list `RunnerBar` as a dependency. Triggers Xcode 26 `XCTTargetAppPath` bug. |
| **Build app separately, then test** | `xcodebuild build -scheme RunnerBar` first, then `xcodebuild test -scheme RunnerBarUITests`. Share `-derivedDataPath`. |
| **LSUIElement apps are `.runningBackground`** | Never `.runningForeground`. |
| **Use bundle ID init** | `XCUIApplication(bundleIdentifier:)` — not default init. |
| **No `XCTTargetAppPath` in scheme** | Xcode 26 strips `.app` → bundle ID read fails. |
| **No `testTargetApp` in UITests scheme** | Same bug. Use dedicated scheme. |
| **`UI_TESTING` in `environmentVariables`** | Not `commandLineArguments`. |
| **`pull_request` trigger only** | Avoids duplicate runs when a PR is open on the feature branch. |
| **No mouse events in CI** | AX read-only. Use `OPEN_PANEL_ON_LAUNCH` env var for panel tests. |
| **Runner must be a user LaunchAgent** | GUI session required. System daemons have no screen. |
| **`openPanel()` needs a real status item position** | For UI tests, use `panel.setFrameOrigin(visibleFrame-based) + orderFront(nil)`. Never call `openPanel()` from `OPEN_PANEL_ON_LAUNCH`. |
| **NSPanel at `.popUpMenu` is INVISIBLE to XCTest AX** | XCTest's AX server excludes `.popUpMenu`-level panels from `app.windows`. Set `panel.level = .floating` when `OPEN_PANEL_ON_LAUNCH` is set. Never expect XCTest to see a `.popUpMenu` window. |
