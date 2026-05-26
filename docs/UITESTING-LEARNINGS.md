# UI Testing — Learnings & Known Pitfalls

This file is a living log. Every time something fails, write it down here **before** pushing a fix.
The goal is to stop re-discovering the same mistakes.

---

## The Setup

- macOS self-hosted runner (`run-bar-runner-1`) running as a Launch Agent (has GUI/WindowServer session)
- App is `LSUIElement = YES` — no Dock icon, no app switcher, status bar only
- App uses `NSPanel`, not `NSPopover`
- XcodeGen generates `RunnerBar.xcodeproj` from `project.yml` at CI time — never committed
- `--uitesting` launch argument bypasses Keychain and GitHub API polling
- macOS 26 / Xcode 26, SDK `MacOSX26.5`

---

## ❌ Things That Do NOT Work

### 1. `app.wait(for: .runningForeground, timeout:)`
**Why it fails:** `LSUIElement = YES` apps never enter `runningForeground`. The process launches into `runningBackground` and stays there. This assertion will always time out and fail.
**Fix:** Use `app.wait(for: .runningBackground, timeout: 5)`.

---

### 2. `controlCentre.statusItems.firstMatch` for clicking RunnerBar's icon
**Why it fails:** On macOS 26, `firstMatch` resolves to **`com.apple.menuextra.battery`** — the Battery item appears first in the accessibility tree, before RunnerBar. Clicking it does nothing and the panel never opens.

Evidence from CI log:
```
Check for interrupting elements affecting com.apple.menuextra.battery StatusItem
```
**Fix:** Set `button.setAccessibilityIdentifier("RunnerBarStatusItem")` on the button in app code, then query `controlCentre.statusItems["RunnerBarStatusItem"]` in tests.

---

### 3. `XCUIApplication(bundleIdentifier: "com.apple.systemuiserver")` for status items
**Why it fails:** On macOS 13+, status items are no longer hosted by `systemuiserver`. They moved to `com.apple.controlcenter`. Querying `systemuiserver` returns an app that either doesn't exist or has no status items.
**Fix:** Always use `XCUIApplication(bundleIdentifier: "com.apple.controlcenter")`.

---

### 4. Running `build.sh` before `xcodebuild test`
**Why it fails:** `build.sh` compiles a **Release** universal binary into `dist/RunnerBar.app`. `xcodebuild test` expects to find the host app at `$(BUILT_PRODUCTS_DIR)/RunnerBar.app` inside DerivedData (Debug config). These are two different paths.
**Fix:** Remove the `Build app` step from the workflow entirely. `xcodebuild test` builds the Debug app itself before running tests.

---

### 5. Setting `TEST_HOST` or `BUNDLE_LOADER` on a `bundle.ui-testing` target
**Why it fails:** `bundle.ui-testing` automatically sets `USES_XCTRUNNER=YES`. Xcode 26 treats `TEST_HOST + USES_XCTRUNNER` as an invalid combination and refuses to build with:
```
Invalid configuration: RunnerBarUITests sets both USES_XCTRUNNER and either TEST_HOST or RUNTIME_TEST_HOST
```
**Fix:** Remove `TEST_HOST` and `BUNDLE_LOADER` entirely from `RunnerBarUITests` settings. Never add them back.

---

### 6. Passing `CODE_SIGNING_REQUIRED=YES` on the xcodebuild command line
**Why it fails:** On Xcode 26, passing `CODE_SIGNING_REQUIRED=YES` as a command-line override causes Xcode to incorrectly flag a `USES_XCTRUNNER + TEST_HOST` conflict on `bundle.ui-testing` targets and refuse to build.
**Fix:** Never pass signing flags on the command line. Let `project.yml` handle signing (`CODE_SIGN_IDENTITY: "-"`, `CODE_SIGNING_REQUIRED: YES` in the target settings).

---

### 7. Stacking multiple unverified commits
**Why it fails:** Each commit assumes the previous fix worked. When CI fails, the failure is now a combination of the old problem plus whatever the new change introduced. After 50+ commits this becomes impossible to untangle.
**Fix:** Run `xcodebuild test` locally on the runner machine and confirm green **before** pushing. Push one change at a time.

---

### 8. `controlCentre.statusItems["com.eoncode.runner-bar"]` on macOS 26
**Why it fails:** On macOS 26 / Xcode 26, the accessibility identifier of a status bar item is **not** the app's bundle ID. `waitForExistence(timeout: 5)` polls the full 5 seconds and returns false.
**Fix:** See learning #9 — set an explicit accessibility identifier on the button and query by that.

---

### 9. No explicit `accessibilityIdentifier` on the `NSStatusItem` button
**Why it fails:** Without a hard-coded identifier, there is no stable string to query the button by in XCUI. Bundle ID lookup (#8) and `firstMatch` (#2) both fail on macOS 26.

**Fix (app side):** In `AppDelegate+StatusItem.swift`, after configuring the button:
```swift
button.setAccessibilityIdentifier("RunnerBarStatusItem")
```

**Fix (test side):**
```swift
let statusItem = controlCentre.statusItems["RunnerBarStatusItem"]
```

---

### 10. Using `-only-testing` without a prior explicit host app build on Xcode 26
**Why it fails:** On Xcode 26, `-only-testing RunnerBarUITests` narrows the build graph and does **not** trigger the `RunnerBar` scheme dependency. `RunnerBar.app` is never placed in `BuildProducts/Debug/`.
```
The bundle identifier for RunnerBar couldn't be read.
No such file or directory: …/.derived/BuildProducts/Debug/RunnerBar.
```
**Fix:** Add an explicit `xcodebuild build` step for the `RunnerBar` scheme **before** the test step, sharing the same `-derivedDataPath`.

---

### 11. Missing `app:` in scheme test targets / missing host app in scheme build targets
**Why it fails:** On Xcode 26, `xcodebuild test` resolves the host app path through the scheme test action. Without `app: RunnerBar` on the `RunnerBarUITests` entry in `project.yml`'s scheme test targets, xcodebuild constructs the path as:
```
BuildProducts/Debug/RunnerBar.
```
(trailing dot, no `.app` extension) and immediately errors:
```
The bundle identifier for RunnerBar couldn't be read.
No such file or directory: …/.derived/BuildProducts/Debug/RunnerBar.
```
This happens even when `RunnerBar.app` physically exists in `BuildProducts/Debug/` — the path resolution is wrong at the scheme level, not the filesystem level.

**Fix in `project.yml`:**
```yaml
schemes:
  RunnerBar:
    test:
      targets:
        - target: RunnerBarUITests
          app: RunnerBar   # ← required on Xcode 26
```
❌ **Never** use the short-form `- RunnerBarUITests` for UI test targets in the scheme. Always use the long-form `target:` + `app:` map.

---

### 12. Using `all` for a build target in the scheme on Xcode 26
**Why it fails:** XcodeGen's `all` shorthand (e.g. `RunnerBar: all`) does **not** reliably populate the `TestAction` element in the generated `.xcscheme` on Xcode 26. When the TestAction is empty or missing, xcodebuild reports:
```
xcodebuild: error: Scheme RunnerBar is not currently configured for the test action.
```
This happens even when the `test:` block and `RunnerBarUITests` target are fully correct.

**Fix:** Always list build actions explicitly on every target:
```yaml
schemes:
  RunnerBar:
    build:
      targets:
        RunnerBar: [build, run, test, profile, analyze, archive]
        RunnerBarUITests: [test]
```
❌ **Never** use `RunnerBar: all` in the scheme build targets.

---

## ✅ Confirmed Working Patterns

- `app.wait(for: .runningBackground, timeout: 5)` — correct state check for LSUIElement apps
- `XCUIApplication(bundleIdentifier: "com.apple.controlcenter")` — correct host for status items on macOS 13+
- `button.setAccessibilityIdentifier("RunnerBarStatusItem")` + `controlCentre.statusItems["RunnerBarStatusItem"]` — the only reliable way to target the status item on macOS 26
- `app.windows.firstMatch` — correct way to query the NSPanel (never `app.popovers`)
- `concurrency: group: ui-test-${{ github.repository }}, cancel-in-progress: false` — serializes runs on the single self-hosted machine
- `--uitesting` launch argument — required to bypass Keychain prompts in CI
- No `TEST_HOST` / `BUNDLE_LOADER` on `bundle.ui-testing` targets
- Explicit `xcodebuild build` step before `xcodebuild test -only-testing` — required on Xcode 26
- `app: RunnerBar` on the UI test target in the scheme test action — required on Xcode 26 for correct `.app` path resolution
- Explicit action list `[build, run, test, profile, analyze, archive]` on main app target in scheme — required on Xcode 26 (never use `all`)

---

## Process Rules (to stop repeating mistakes)

1. **Read the exact failure line** before writing any fix. Not the full 300KB log — just the `XCTAssert` or `error:` line.
2. **Run locally first.** If you can't confirm green on the runner machine, don't push.
3. **One change per commit.** Never bundle workflow + project.yml + test file in one push.
4. **Update this file** every time something new fails, before pushing the fix.
5. **Check the learnings file first.** Before writing any fix, read this file top to bottom.
