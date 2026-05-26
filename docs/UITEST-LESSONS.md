# UI Test CI — What Doesn't Work (Lessons Learned)

Running log of failures on `feature/936-xcodegen-uitest-setup`.  
Update this file every time something new breaks. Do **not** delete old entries.

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
**Fix:** Keep all CI tests READ-ONLY — only query the AX tree, never synthesise input events. The click test (`testPanelOpensOnClick`) was removed for this reason.

---

## CI Workflow — `ui-tests.yml`

### ❌ `xcpretty` on macOS arm64 (system Ruby 2.6)
**Error:** `xcpretty` gem install fails or crashes on Apple Silicon with system Ruby 2.6.  
**Fix:** Drop `xcpretty`. Use raw `xcodebuild` output. The signal-to-noise ratio is worse but it actually works.

---

### ❌ Runner installed as a system `LaunchDaemon` (`/Library/LaunchDaemons/`)
**Error:** No GUI session available → XCUIApplication can't launch.  
**Fix:** The runner must be installed as a user `LaunchAgent` (`~/Library/LaunchAgents/`).  
One-time fix on the runner machine:
```bash
sudo ./svc.sh uninstall
./svc.sh install && ./svc.sh start
```

---

### ❌ `xcode-select` pointing at CommandLineTools instead of Xcode.app
**Error:** `xcodebuild` fails — no full SDK available.  
**Fix (one-time on runner machine):**
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```
The workflow validates this at startup and exits with a clear error if not fixed.

---

## General Rules (Don't Forget)

| Rule | Detail |
|------|--------|
| **Never use CI as a scratch pad** | Validate `xcodegen generate && xcodebuild test` locally before committing. |
| **`bundle.ui-testing` ≠ `bundle.unit-test`** | Different signing, no `TEST_HOST`, no `BUNDLE_LOADER`, uses XCTRunner. |
| **LSUIElement apps are `.runningBackground`** | Never `.runningForeground`. |
| **Use bundle ID init** | `XCUIApplication(bundleIdentifier:)` — not default init — on Xcode 26 + LSUIElement. |
| **No `XCTTargetAppPath` in scheme** | Xcode 26 strips `.app` from the path → bundle ID read fails. Remove it entirely. |
| **No mouse events in CI** | AX read-only queries only. Input synthesis moves the real cursor. |
| **Runner must be a user LaunchAgent** | GUI session required for UI tests. System daemons have no screen. |
