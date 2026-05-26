# UI Test CI — What Doesn't Work (and What Does)

Running log of the `feature/936-xcodegen-uitest-setup` branch.  
Update this file every time something new breaks or works. Do **not** delete old entries.

---

## ✅ CONFIRMED WORKING — testSettingsNavigationFlow passes (2026-05-26, 07:07 CEST)

**Local run output:**
```
Test Case '-[RunnerBarUITests.RunnerBarUITests testSettingsNavigationFlow]' passed (22.525 seconds).
Executed 1 test, with 0 failures (0 unexpected) in 22.525 seconds
** TEST SUCCEEDED **
```

**Passing config:**
- `coordinate(withNormalizedOffset: CGVector(dx:0.5, dy:0.5)).click()` for all panel button taps
- Global event monitor disabled when `UI_TESTING` is set (AppDelegate)
- `staticTexts["Active local runners"]` as Settings arrival proof (not `staticTexts["Settings"]`)
- `buttons.matching(identifier:"plus").element(boundBy: N)` to disambiguate the two Add buttons
- No `isHittable` check anywhere
- No `app.windows` anywhere

---

## ✅ CONFIRMED WORKING — 3/3 tests pass (2026-05-26, 05:43 CEST)

**Local run output:**
```
Test Suite RunnerBarUITests passed at 2026-05-26 05:43:20
Executed 3 tests, with 0 failures (0 unexpected) in 9.656 seconds
  ✅ testAppLaunchesWithoutCrashing       — 2.472s
  ✅ testPanelOpensAndShowsWorkflowsSection — 4.597s
  ✅ testStatusBarItemExists              — 2.587s
```

**Passing config — 3 tests, 0 failures:**
- `type: bundle.ui-testing` in project.yml — no `TEST_HOST`, no `BUNDLE_LOADER`
- `CODE_SIGN_IDENTITY: "-"` + `CODE_SIGNING_REQUIRED: NO` + `AD_HOC_CODE_SIGNING_ALLOWED: YES`
- `GENERATE_INFOPLIST_FILE: YES` on `RunnerBarUITests`
- `XCUIApplication(bundleIdentifier: "dev.eonist.runnerbar")` — NOT default init
- `app.wait(for: .runningForeground, timeout:)` — works because `setActivationPolicy(.regular)` is called in `applicationWillFinishLaunching`
- **No `dependencies` on `RunnerBar` in the `RunnerBarUITests` target** — prevents Xcode 26 from auto-injecting `XCTTargetAppPath`
- **No `testTargetApp` in scheme** — same reason
- **`UI_TESTING` as `environmentVariables`** in scheme, NOT `commandLineArguments`
- **Dedicated `RunnerBarUITests` scheme** used for `xcodebuild test`
- **App built in a separate step** before `xcodebuild test`; both steps share `-derivedDataPath`
- **Status item click** to open panel — works because `.regular` activation policy makes the app fully AX-visible
- **`app.staticTexts["WORKFLOWS"]`** to assert panel content — NOT `app.windows` (see lesson below)

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
**Error:** `The bundle identifier for RunnerBar couldn't be read.` — persists even with a dedicated scheme.  
**Why:** On Xcode 26, a target-level dependency from a `bundle.ui-testing` target to an app target triggers auto-injection of `XCTTargetAppPath` regardless of scheme configuration. Xcode sees "this UI test bundle depends on this app" and wires the path internally — then strips `.app` from it.  
**Fix:** Remove `dependencies` from `RunnerBarUITests` entirely. Build the app in a **separate `xcodebuild build` step** first, then run `xcodebuild test`. Both steps share `-derivedDataPath`.  
**Rule:** On Xcode 26, `bundle.ui-testing` targets must have **zero target dependencies** on the app.

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
**Problem:** Every push fires two runs.  
**Fix:** Use only `pull_request` trigger.

---

## XCUIApplication — Test Code

### ❌ `XCUIApplication()` default init with LSUIElement app on Xcode 26
**Error:** App resolves wrong path; test fails to launch.  
**Fix:** Always use `XCUIApplication(bundleIdentifier: "dev.eonist.runnerbar")`.

---

### ❌ `app.wait(for: .runningForeground)` without `setActivationPolicy(.regular)`
**Error:** Times out — LSUIElement apps run as `.runningBackground` by default.  
**Fix:** Add `NSApp.setActivationPolicy(.regular)` + `NSApp.activate(ignoringOtherApps: true)` in `applicationWillFinishLaunching` when `UI_TESTING` is set. Must be `WillFinish`, not `DidFinish`.  
**Rule:** `setActivationPolicy` must fire before the XCTest automation session handshake.

---

### ❌ `app.windows` always empty for a `[.borderless, .nonactivatingPanel]` NSPanel
**Error:** `waitForExistence(timeout: 5)` on `app.windows.firstMatch` always times out, even when the panel is visually open.  
**Why:** `app.windows` in XCUITest only enumerates windows with an **activating** style mask. `NSPanel` with `[.borderless, .nonactivatingPanel]` is permanently invisible to `app.windows` — regardless of window level (`.popUpMenu`, `.floating`, `.normal`), activation policy (`.regular` vs `.background`), or whether the panel is on-screen.  
**This was the root cause** of the final failure. Window level changes (`.popUpMenu` → `.floating`) were a red herring — they made no difference because the problem is the style mask, not the level.  
**Fix:** Query panel content directly: `app.staticTexts["WORKFLOWS"].waitForExistence(timeout: 5)`. Static texts inside the panel ARE in the AX tree; only the window container itself is hidden from `app.windows`.  
**Rule:** ❌ NEVER use `app.windows` to find the RunnerBar panel. It will always be empty. Query content elements directly.

---

### ❌ Global `NSEvent.addGlobalMonitorForEvents` dismisses panel on XCTest synthesized clicks
**Problem:** AppDelegate installs a global mouse-down monitor to close the panel when the user
clicks elsewhere. XCTest synthesizes `CGEvent` mouse clicks that also fire this monitor.
If the synthesized click coordinate lands outside `panel.frame` (even by 1pt), `closePanel()`
is called and the app terminates the test.
**Fix:** Guard monitor installation with `UI_TESTING`:
```swift
guard ProcessInfo.processInfo.environment["UI_TESTING"] == nil else { return }
eventMonitor = NSEvent.addGlobalMonitorForEvents(...)
```
**Rule:** ❌ NEVER install a global event monitor during UI tests. The monitor sees XCTest's synthesized events and closes the panel.

---

### ❌ `.click()` misfires on elements inside a borderless `nonActivatingPanel`
**Root cause:** `.click()` synthesizes a `CGEvent` in **Quartz screen coordinates** (origin = bottom-left,
Y increases upward). The AX frame reported by XCTest is in **HIServices coordinates** (origin = top-left,
Y increases downward). For a normal key window AppKit applies a flip transform when routing the event.
For a borderless `nonActivatingPanel` that **never becomes key**, that transform is never applied —
so the click lands at the Y-mirrored screen position, which is outside the panel.
**Fix:**
```swift
element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
```
Normalised-offset clicks are computed **relative to the element's own bounds**, not absolute screen
space — the coordinate-space flip is irrelevant.
**Rule:** ❌ NEVER call `.click()` directly on elements inside the panel. Always use
`.coordinate(withNormalizedOffset: CGVector(dx:0.5, dy:0.5)).click()`.

---

### ❌ `isHittable` always `false` for buttons inside a `nonActivatingPanel`
**Why:** The panel never becomes the key window, so XCTest's AX hit-test check at the
window level always returns `false` — even when the button is fully visible and clickable.
**Fix:** Remove all `isHittable` predicates. `waitForExistence` is sufficient.
**Rule:** ❌ NEVER wait for `isHittable` on elements inside the RunnerBar panel.

---

### ❌ `staticTexts["Settings"]` to verify SettingsView is open
**Why:** `Text("Settings")` in `SettingsView.headerBar` is **nested inside a `Button`**. SwiftUI
folds nested `Text` into the button's AX label — it does NOT create a standalone `AXStaticText`
node. `app.staticTexts["Settings"]` therefore always returns zero matches.
**Fix:** Use `app.staticTexts["Active local runners"]` — the first unconditional `Text()` section
header in `SettingsView`, which IS a standalone `AXStaticText`.
**Rule:** ❌ NEVER assert `app.staticTexts["Settings"]` to verify Settings is open.
✓ Use `app.staticTexts["Active local runners"].waitForExistence(timeout: 5)`.

---

### ❌ `app.buttons["Add new"]` / `app.buttons["Add pre-existing"]` / `app.buttons["Organisation"]` / `app.buttons["Repository"]`
**Why:** These labels come from `Picker` with `.pickerStyle(.segmented)`. On macOS, a segmented
Picker renders as `NSSegmentedControl`. In the AX tree its segments appear as `AXRadioButton`
children of an `AXRadioGroup` — **never as `AXButton` elements**. `app.buttons["Add new"]`
always returns zero matches.
**Fix:** Assert the sheet's title `Text` instead: `app.staticTexts["Add runner"]`.
**Rule:** ❌ NEVER assert `app.buttons[]` for segmented Picker segments. Query `staticTexts` for
proof-of-arrival.

---

### ❌ Two `plus` buttons with identical label and identifier in SettingsView
**Why:** `localRunnersSectionHeader` and `remoteScopesSectionHeader` both have
`Image(systemName: "plus")` buttons. Both resolve to `identifier: "plus"`, `label: "Add"`
in the AX tree. `app.buttons["Add a new runner"]` and `app.buttons["Add a remote scope"]`
work via `.help()` text but are fragile if help strings change.
**Fix:** Disambiguate by index:
```swift
app.buttons.matching(identifier: "plus").element(boundBy: 0) // Add runner
app.buttons.matching(identifier: "plus").element(boundBy: 1) // Add scope
```
**Rule:** When multiple elements share the same identifier, use `boundBy:` index.

---

### ❌ Chasing window level (`.popUpMenu` → `.floating`) as the cause of `app.windows` being empty
**Why this was wrong:** The correct hypothesis was partially documented in this file (the `LSUIElement + app.windows` lesson above), but we re-investigated it as the cause of a new failure instead of checking whether the panel style mask was the culprit. Three separate CI pushes and one clean build were wasted on this.  
**Lesson:** Before pushing any fix, re-read this file. The `app.windows always empty` lesson was already documented.

---

### ❌ `app.popovers` for an `NSPanel`-based app
**Error:** `app.popovers.firstMatch` never exists.  
**Fix:** The panel is not a popover. Query content via `app.staticTexts`.

---

### ❌ Synthesising click/mouse events in CI on a shared active desktop
**Problem:** `XCUIApplication.click()` physically moves the mouse cursor and steals focus.  
**Note:** Status item click works fine when the app has `.regular` activation policy and a real GUI session.

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
| **`setActivationPolicy(.regular)` in `WillFinishLaunching`** | Must fire before XCTest automation handshake. Required to use `.runningForeground` and `app.statusItems`. |
| **Use bundle ID init** | `XCUIApplication(bundleIdentifier:)` — not default init on Xcode 26. |
| **No `XCTTargetAppPath` in scheme** | Xcode 26 strips `.app` → bundle ID read fails. |
| **No `testTargetApp` in UITests scheme** | Same bug. Use dedicated scheme. |
| **`UI_TESTING` in `environmentVariables`** | Not `commandLineArguments`. |
| **`pull_request` trigger only** | Avoids duplicate runs when a PR is open on the feature branch. |
| **`app.windows` is ALWAYS EMPTY for `[.borderless, .nonactivatingPanel]`** | The style mask hides the window from `app.windows` permanently. Query `app.staticTexts` directly. |
| **Window level is NOT the cause of `app.windows` being empty** | `.popUpMenu` vs `.floating` makes no difference. The culprit is `nonactivatingPanel`. |
| **Never rewrite tests before committing app-side code** | Verify app code exists (`grep`/search) before pushing tests that depend on it. |
| **Clean build after app source changes** | `xcodebuild test -scheme RunnerBarUITests` does NOT recompile app sources. Run `xcodebuild clean + build -scheme RunnerBar` first. |
| **Disable global event monitor during UI tests** | `NSEvent.addGlobalMonitorForEvents` sees XCTest's synthesized clicks and dismisses the panel. Guard with `UI_TESTING`. |
| **Use `.coordinate(withNormalizedOffset:).click()` always** | Direct `.click()` misfires on `nonActivatingPanel` due to Quartz/HIServices Y-axis flip. Normalised-offset is element-relative — no flip. |
| **`isHittable` is always false on panel buttons** | Panel never becomes key. Drop all `isHittable` predicates. |
| **`Text` inside `Button` is NOT a standalone `AXStaticText`** | SwiftUI folds it into the button label. Never assert nested `Text` via `staticTexts[]`. |
| **Picker `.segmented` segments are `AXRadioButton`, not `AXButton`** | `app.buttons["Add new"]` etc. will always fail. Assert `staticTexts` for proof-of-arrival. |
| **Disambiguate duplicate `plus` buttons by `boundBy:` index** | Two `plus` SFSymbol buttons in SettingsView share identical AX identity. |
