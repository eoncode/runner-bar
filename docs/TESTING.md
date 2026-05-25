# Testing

## Overview

runner-bar has two layers of tests:

| Type | Runner | Command |
|---|---|---|
| Unit tests | Any machine | `swift test` |
| UI tests (XCUITest) | Self-hosted only | `xcodebuild test` via CI |

Unit tests run anywhere via SPM. UI tests require a self-hosted macOS runner with a GUI session — see below.

---

## Unit Tests

```bash
swift test
```

No setup required. Runs on any machine with the Swift toolchain installed.

---

## UI Tests

UI tests use XCUITest via a XcodeGen-generated `.xcodeproj`. The project file is **never committed** — it is generated at CI time from `project.yml` and gitignored.

Because runner-bar is an `LSUIElement` app (no Dock icon, no app switcher), tests run completely invisibly. The status bar icon appears briefly during panel interaction tests, then disappears on teardown.

### How It Works

1. `xcodegen generate --spec project.yml` produces `RunnerBar.xcodeproj` on the runner
2. SPM package dependencies are resolved via `xcodebuild -resolvePackageDependencies`
3. The app is built and launched with `--uitesting` launch argument
4. `--uitesting` bypasses Keychain reads and GitHub API polling — the app boots with empty state
5. XCUITest interacts with the status bar item and NSPanel
6. `.xcresult` is uploaded as a CI artifact

### Self-Hosted Runner Setup

The UI test workflow (`ui-tests.yml`) runs on `self-hosted`. The following **one-time manual steps** are required on the runner machine before tests will pass.

#### 1. Register runner as a Launch Agent (not daemon)

The runner must be installed as a Launch Agent so it runs in a GUI/WindowServer session. A daemon has no screen access and XCUITest will fail silently.

```bash
cd ~/actions-runner
./svc.sh install
./svc.sh start
```

Verify it is running as a Launch Agent:
```bash
ls ~/Library/LaunchAgents/ | grep actions
```

#### 2. Grant Accessibility permission to xcodebuild

> ⚠️ This step **cannot be automated** on SIP-enabled macOS. It must be done once manually. It persists forever across reboots.
>
> **If you skip this step**, macOS will show a Touch ID / password prompt mid-CI run saying _“XCTest is trying to Enable UI Automation”_. The CI job will hang waiting for approval and eventually time out.

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Click the `+` button
3. Navigate to:
   ```
   /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
   ```
4. Ensure the toggle next to `xcodebuild` is **on**

Do **not** add `/usr/bin/xcodebuild` (the shim) — add the real binary inside `Xcode.app`. Once added this permission survives reboots and Xcode updates within the same major version.

#### 3. Install dependencies (automated by CI)

The workflow installs `xcodegen` automatically if not present:

```bash
brew install xcodegen
```

### Running UI Tests Locally

Once the runner setup above is complete, you can run UI tests manually:

```bash
# Generate the Xcode project
xcodegen generate --spec project.yml

# Resolve SPM packages
xcodebuild -resolvePackageDependencies \
  -project RunnerBar.xcodeproj \
  -scheme RunnerBar

# Build
./build.sh

# Run UI tests
xcodebuild test \
  -project RunnerBar.xcodeproj \
  -scheme RunnerBar \
  -destination 'platform=macOS' \
  -only-testing RunnerBarUITests \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES
```

### Test Coverage

| Test | What it verifies |
|---|---|
| `testAppLaunchesWithoutCrashing` | App process starts and reaches runningForeground state |
| `testStatusBarItemExists` | NSStatusItem appears in the menu bar |
| `testPanelOpensOnClick` | Clicking status item opens the NSPanel |
| `testPanelDismissesOnSecondClick` | Clicking status item again closes the NSPanel |

> ⚠️ runner-bar uses `NSPanel`, not `NSPopover`. Always query `app.windows` in tests — never `app.popovers`.

### The `--uitesting` Launch Argument

The app checks `ProcessInfo.processInfo.arguments.contains("--uitesting")` at launch. When set:
- Keychain reads are skipped — no system approval prompt in CI
- GitHub API polling is not started
- App boots with empty runner/job state

This is set automatically by `XCUIApplication.launchArguments` in `setUp()` and requires no manual action.

---

## CI Workflows

| Workflow | File | Trigger |
|---|---|---|
| UI Tests | `.github/workflows/ui-tests.yml` | push to main, all PRs |

Test results (`.xcresult`) are uploaded as artifacts on every run, including failures.
