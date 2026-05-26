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
- **No `testTargetApp` in scheme** — omitting it prevents Xcode 26 from auto-injecting `XCTTargetAppPath`
- **`UI_TESTING` as `environmentVariables`** in scheme, NOT `commandLineArguments`
- **Dedicated `RunnerBarUITests` scheme** used for `xcodebuild test`, NOT the `RunnerBar` app scheme
- `xcodebuild test -scheme RunnerBarUITests -only-testing:RunnerBarUITests` on self-hosted runner with GUI session

---

## project.yml — XcodeGen Configuration

### ❌ `TEST_HOST` + `BUNDLE_LOADER` on a `bundle.ui-testing` target
**Error:** `Invalid configuration: RunnerBarUITests sets both USES_XCTRUNNER and either TEST_HOST or RUNTIME_TEST_HOST`  
**Why:** `type: bundle.ui-testing` automatically sets `USES_XCTRUNNER=YES`. This flag is mutually exclusive with `TEST_HOST`/`BUNDLE_LOADER`, which are for unit test bundles that inject into the host app process. UI tests always run out-of-process via XCTRunner.  
**Fix:** Remove `TEST_HOST` and `BUNDLE_LOADER` entirely from the `RunnerBarUITests` settings block.  
**Rule:** Never mix `bundle.ui-testing` with `TEST_HOST`/`BUNDLE_LOADER`. Those two keys belong only on `bundle.unit-test` targets.

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
**Fix:** Add `GENERATE_INFOPLIST_FILE: YES` to `RunnerBarUITests` settings. The app target uses a hand-written `Info.plist`; the test bundle should have it auto-generated.

---

### ❌ `RunnerBarUITests` not wired into the scheme's test action
**Error:** `xcodebuild test -only-testing:RunnerBarUITests` finds nothing to run.  
**Fix:** The `schemes.RunnerBar.test.targets` list must explicitly include `RunnerBarUITests`. XcodeGen does not infer it.

---

### ❌ Using the `RunnerBar` app scheme for `xcodebuild test` (Xcode 26)
**Error:** `The bundle identifier for RunnerBar couldn't be read. No such file or directory: ".../Debug/RunnerBar"`  
**Why:** When `RunnerBarUITests` is wired into the `RunnerBar` app scheme's test action (even without an explicit `testTargetApp` key), Xcode 26 auto-populates `XCTTargetAppPath` internally, pointing at `.../Debug/RunnerBar` — with the `.app` extension stripped. The test runner then fails to read the bundle ID from that path.  
**Fix:** Create a **dedicated `RunnerBarUITests` scheme** that includes only the build/test targets and has **no `testTargetApp`** key. Run `xcodebuild test -scheme RunnerBarUITests` instead of `-scheme RunnerBar`.  
**Rule:** On Xcode 26, UI tests must use a dedicated scheme with no `testTargetApp`. Never run UI tests via the app's own scheme.

---

### ❌ `UI_TESTING` in scheme `commandLineArguments` instead of `environmentVariables`
**Error:** `ProcessInfo.processInfo.environment["UI_TESTING"]` is always `nil` in the app — network/keychain guard never triggers.  
**Why:** `commandLineArguments` in an XcodeGen scheme become `argv[]` entries (prefixed with `-`), not environment variables. `ProcessInfo.processInfo.environment` only sees env vars, not CLI args.  
**Fix:** Move `UI_TESTING` from `commandLineArguments` to `environmentVariables` in the scheme's `test` block.  
**Rule:** Anything the app reads via `ProcessInfo.processInfo.environment["KEY"]` must be in `environmentVariables`, not `commandLineArguments`.

---

### ❌ `XCTTargetAppPath` in scheme `environmentVariables` (Xcode 26)
**Error:** `The bundle identifier for RunnerBar couldn't be read. No such file or directory: ".../Build/Products/Debug/RunnerBar"`  
**Why:** Xcode 26's test runner uses `XCTTargetAppPath` to locate the app and read its bundle ID — but it strips the `.app` extension from the path, making the directory lookup fail. This triggers even when test code correctly uses `XCUIApplication(bundleIdentifier:)`.  
**Fix:** **Do not set `XCTTargetAppPath` in the scheme at all.** When using `XCUIApplication(bundleIdentifier:)`, the runtime locates the app through Launch Services. Setting `XCTTargetAppPath` is redundant and triggers the broken Xcode 26 path handling.  
**Rule:** On Xcode 26, `XCTTargetAppPath` in scheme env = broken. Remove it. Trust Launch Services + bundle ID init.

---

## XCUIApplication — Test Code

### ❌ `XCUIApplication()` default init with LSUIElement app on Xcode 26
**Error:** App resolves wrong path; test fails to launch.  
**Why:** Xcode 26 has a bug where `XCUIApplication()` strips the `.app` extension from `XCTTargetAppPath` for `LSUIElement` apps.  
**Fix:** Always use `XCUIApplication(bundleIdentifier: "dev.eonist.runnerbar")`.

---

### ❌ `app.wait(for: .runningForeground, timeout:)` on a `LSUIElement` menu bar agent
**Error:** Test always times out — app never reaches `.runningForeground`.  
**Why:** `LSUIElement = true` apps are background agents; they never become the foreground app.  
**Fix:** Use `.runningBackground` instead.

---

### ❌ `app.popovers` for an `NSPanel`-based app
**Error:** `app.popovers.firstMatch` never exists.  
**Why:** The panel is an `NSPanel`, not an `NSPopover`. They are different AX elements.  
**Fix:** Use `app.windows` to access the panel.

---

### ❌ Synthesising click/mouse events in CI on a shared active desktop
**Problem:** `XCUIApplication.click()` and similar input-synthesis APIs physically move the mouse cursor and steal focus. This breaks anything else running on the machine.  
**Fix:** Keep all CI tests READ-ONLY — only query the AX tree, never synthesise input events.  
**For panel tests:** Use `OPEN_PANEL_ON_LAUNCH=1` env var instead of clicking the status item (see below).

---

### ✅ How to test the panel without clicking — `OPEN_PANEL_ON_LAUNCH`
**Problem:** The panel only opens via `togglePanel()` which is wired to the status item button click. No click = panel never opens = can't test UI content.  
**Solution:** Add an env var hook in `AppDelegate+PanelSetup.swift`:
```swift
if ProcessInfo.processInfo.environment["OPEN_PANEL_ON_LAUNCH"] != nil {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        self?.openPanel()
    }
}
```
Then in the test:
```swift
app.launchEnvironment["OPEN_PANEL_ON_LAUNCH"] = "1"
app.launch()
let panel = app.windows.firstMatch
XCTAssertTrue(panel.waitForExistence(timeout: 5))
let workflowsHeader = app.staticTexts["Workflows"]
XCTAssertTrue(workflowsHeader.waitForExistence(timeout: 5))
```
**Rule:** `OPEN_PANEL_ON_LAUNCH` is the canonical way to open the panel in CI. Never click.

---

## CI Workflow — `ui-tests.yml`

### ❌ `xcpretty` on macOS arm64 (system Ruby 2.6)
**Error:** `xcpretty` gem install fails or crashes on Apple Silicon with system Ruby 2.6.  
**Fix:** Drop `xcpretty`. Use raw `xcodebuild` output.

---

### ❌ Runner installed as a system `LaunchDaemon` (`/Library/LaunchDaemons/`)
**Error:** No GUI session available → XCUIApplication can't launch.  
**Fix:** The runner must be installed as a user `LaunchAgent` (`~/Library/LaunchAgents/`).  
One-time fix:
```bash
sudo ./svc.sh uninstall
./svc.sh install && ./svc.sh start
```

---

### ❌ `xcode-select` pointing at CommandLineTools instead of Xcode.app
**Error:** `xcodebuild` fails — no full SDK available.  
**Fix (one-time):**
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

---

## General Rules (Don't Forget)

| Rule | Detail |
|------|--------|
| **Never use CI as a scratch pad** | Validate `xcodegen generate && xcodebuild test` locally before committing. |
| **`bundle.ui-testing` ≠ `bundle.unit-test`** | No `TEST_HOST`, no `BUNDLE_LOADER`, uses XCTRunner. |
| **LSUIElement apps are `.runningBackground`** | Never `.runningForeground`. |
| **Use bundle ID init** | `XCUIApplication(bundleIdentifier:)` — not default init — on Xcode 26 + LSUIElement. |
| **No `XCTTargetAppPath` in scheme** | Xcode 26 strips `.app` from the path → bundle ID read fails. Remove it entirely. |
| **No `testTargetApp` in UITests scheme** | Xcode 26 auto-injects `XCTTargetAppPath` when present → same `.app`-stripping bug. Use dedicated scheme. |
| **`UI_TESTING` in `environmentVariables`, not `commandLineArguments`** | CLI args are not env vars. `ProcessInfo.processInfo.environment` won't see them. |
| **Use dedicated `RunnerBarUITests` scheme** | Never run UI tests via the app scheme. Dedicated scheme = no auto-injected `XCTTargetAppPath`. |
| **No mouse events in CI** | AX read-only queries only. Use `OPEN_PANEL_ON_LAUNCH` to open the panel instead. |
| **Runner must be a user LaunchAgent** | GUI session required for UI tests. System daemons have no screen. |
