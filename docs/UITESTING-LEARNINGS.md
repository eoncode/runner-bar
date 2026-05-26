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

### 2. `controlCentre.statusItems.firstMatch` for clicking RunnerBar’s icon
**Why it fails:** On macOS 13+, all status bar items live inside `com.apple.controlcenter`. `firstMatch` resolves to whatever item happens to be first in the accessibility tree — usually the system Battery or Wi-Fi item, not RunnerBar. Clicking it does nothing useful and the test fails.
**Fix:** Query by identifier: `controlCentre.statusItems["com.eoncode.runner-bar"]`.

> ⚠️ **macOS 26 exception — see learning #8 below.** The bundle-ID identifier lookup is broken on macOS 26; `firstMatch` is the correct approach there.

---

### 3. `XCUIApplication(bundleIdentifier: "com.apple.systemuiserver")` for status items
**Why it fails:** On macOS 13+, status items are no longer hosted by `systemuiserver`. They moved to `com.apple.controlcenter`. Querying `systemuiserver` returns an app that either doesn’t exist or has no status items.
**Fix:** Always use `XCUIApplication(bundleIdentifier: "com.apple.controlcenter")`.

---

### 4. Running `build.sh` before `xcodebuild test`
**Why it fails:** `build.sh` compiles a **Release** universal binary into `dist/RunnerBar.app`. `xcodebuild test` expects to find the host app at `$(BUILT_PRODUCTS_DIR)/RunnerBar.app` inside DerivedData (Debug config). These are two different paths. The test runner fails with:
```
The bundle identifier for RunnerBar couldn’t be read.
No such file or directory: .../DerivedData/Debug/RunnerBar.
```
**Fix:** Remove the `Build app` step from the workflow entirely. `xcodebuild test` builds the Debug app itself before running tests.

---

### 5. Setting `TEST_HOST` or `BUNDLE_LOADER` on a `bundle.ui-testing` target
**Why it fails:** `bundle.ui-testing` automatically sets `USES_XCTRUNNER=YES`. Xcode 26 treats `TEST_HOST + USES_XCTRUNNER` as an invalid combination and refuses to build with:
```
Invalid configuration: RunnerBarUITests sets both USES_XCTRUNNER and either TEST_HOST or RUNTIME_TEST_HOST
```
`TEST_HOST` is for **unit test** targets (`bundle.unit-test`), not UI test targets. For UI tests, xcodebuild locates the host app via the scheme’s test action target dependency — no manual path needed.
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
**Why it fails:** On macOS 26 / Xcode 26, the accessibility identifier of a status bar item is **not** the app’s bundle ID. The lookup `statusItems["com.eoncode.runner-bar"]` silently returns an element that never exists — `waitForExistence(timeout: 5)` polls the full 5 seconds then returns `false`.

Evidence from CI log:
```
t 1.63s Checking existence of com.eoncode.runner-bar StatusItem
t 2.63s Checking existence of com.eoncode.runner-bar StatusItem
t 3.61s Checking existence of com.eoncode.runner-bar StatusItem
t 4.62s Checking existence of com.eoncode.runner-bar StatusItem
t 5.60s Checking existence of com.eoncode.runner-bar StatusItem
XCTAssertTrue failed  ← times out after full 5s
```
The smoke test `testStatusBarItemExists` **passes** using `firstMatch`, confirming the item exists in the tree but just isn’t reachable by that string key.

**Fix:** Use `controlCentre.statusItems.firstMatch` in all tests. On the CI machine only one non-system status item is present (RunnerBar itself), so `firstMatch` reliably targets our item.

**Note:** If multiple items are ever present, a better approach would be to find the item’s actual accessibility identifier by capturing the accessibility tree (e.g. via `po controlCentre.statusItems.allElementsBoundByIndex` in an Xcode test session) and hardcoding that string instead of the bundle ID.

---

## ✅ Confirmed Working Patterns

- `app.wait(for: .runningBackground, timeout: 5)` — correct state check for LSUIElement apps
- `XCUIApplication(bundleIdentifier: "com.apple.controlcenter")` — correct host for status items on macOS 13+
- `controlCentre.statusItems.firstMatch` — works on macOS 26 CI (one non-system item present)
- `app.windows.firstMatch` — correct way to query the NSPanel (never `app.popovers`)
- `concurrency: group: ui-test-${{ github.repository }}, cancel-in-progress: false` — serializes runs on the single self-hosted machine, prevents race conditions
- `--uitesting` launch argument — required to bypass Keychain prompts in CI
- No `TEST_HOST` / `BUNDLE_LOADER` on `bundle.ui-testing` targets — xcodebuild resolves the host app via scheme dependency

---

## Process Rules (to stop repeating mistakes)

1. **Read the exact failure line** before writing any fix. Not the full 300KB log — just the `XCTAssert` or `error:` line.
2. **Run locally first.** If you can’t confirm green on the runner machine, don’t push.
3. **One change per commit.** Never bundle workflow + project.yml + test file in one push.
4. **Update this file** every time something new fails, before pushing the fix.
5. **Check the learnings file first.** Before writing any fix, read this file top to bottom.
