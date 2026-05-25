# Testing

RunnerBar has two test layers:

| Layer | Command | Runs on |
|---|---|---|
| Unit tests (`RunnerBarCoreTests`) | `swift test` | Cloud runners + local |
| UI smoke tests (`RunnerBarUITests`) | `xcodebuild` via XcodeGen | Self-hosted runner only |

---

## Unit Tests

```bash
swift test
```

No setup required. These run on every push via the standard CI workflow.

---

## UI Smoke Tests

UI tests use `XCUIApplication` to launch the real app binary and verify the status bar item and panel open correctly. Because `XCUIApplication` requires WindowServer, these tests **must run on a self-hosted Mac with an active GUI session**.

The `.xcodeproj` is generated ephemerally at CI time by [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml` and is never committed to the repo.

### How it works

1. CI runs `xcodegen generate` → creates `RunnerBar.xcodeproj` on-the-fly
2. `xcodebuild test` launches `RunnerBarUITests` scheme
3. The app launches with `UI_TESTING=1` → skips all keychain/network access
4. Three smoke tests run silently in the background (no Dock icon, no windows)
5. `RunnerBar.xcodeproj` is deleted at the end of the job

---

## One-Time Self-Hosted Runner Setup

These steps are required **once per machine**. They are not automated in CI.

### 1. Install Homebrew

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 2. Install XcodeGen

```bash
brew install xcodegen
```

Verify: `xcodegen --version`

### 3. Install Xcode and point xcode-select at it

The full **Xcode.app** must be installed (not just Command Line Tools). `xcodebuild` UI tests require the full toolchain.

```bash
# Check current path
xcode-select -p
# Must return /Applications/Xcode.app/Contents/Developer
# If it returns /Library/Developer/CommandLineTools, fix it:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# Accept the Xcode license if prompted
sudo xcodebuild -license accept

# Verify
xcodebuild -version
```

### 4. Ensure the runner agent runs in a GUI session

`XCUIApplication` and `NSStatusItem` require WindowServer. The runner **must not** run as a system-level `launchd` daemon (which has no GUI).

**Check how your runner is currently installed:**

```bash
# If this returns a file, it’s installed as a user-level launch agent (OK)
ls ~/Library/LaunchAgents/com.github.runner.*.plist

# If this returns a file, it’s a system daemon (NO GUI — fix required)
ls /Library/LaunchDaemons/com.github.runner.*.plist
```

**If installed as a system daemon, reinstall as a user launch agent:**

```bash
cd /path/to/actions-runner
sudo ./svc.sh uninstall   # remove system daemon
./svc.sh install           # installs to ~/Library/LaunchAgents (user-level, has GUI)
./svc.sh start
```

Alternatively, run the runner manually in a Terminal window that stays open:

```bash
cd /path/to/actions-runner && ./run.sh
```

### 5. Grant Accessibility permission to xcodebuild

The `xcodebuild` test runner uses the macOS Accessibility API to drive `XCUIApplication`. It needs explicit permission.

1. Open **System Settings → Privacy & Security → Accessibility**
2. Click **+** and add `/usr/bin/xcodebuild`
   - If `xcodebuild` is not listed after running tests once, add the path manually
3. Ensure the toggle is **on**

> ⚠️ If `testStatusBarItemExists` or `testPanelOpensOnClick` fail with no clear error, missing Accessibility permission is the most likely cause.

### 6. Verify the full setup

Run this checklist from your terminal on the runner machine:

```bash
# Homebrew
brew --version

# XcodeGen
xcodegen --version

# Xcode (must NOT say CommandLineTools)
xcode-select -p
xcodebuild -version

# Runner agent (should show "started")
~/Library/LaunchAgents/com.github.runner.*.plist && launchctl list | grep github
```

---

## Debugging Failed UI Tests

| Symptom | Likely cause | Fix |
|---|---|---|
| `testStatusBarItemExists` fails | No GUI session | Runner must run as user launch agent, not daemon |
| `testPanelOpensOnClick` fails | No GUI session or Accessibility denied | Check GUI session + grant Accessibility permission |
| Keychain approval dialog appears | `UI_TESTING` guard not applied | Verify `AppDelegate+PanelSetup.swift` has the guard |
| `xcodebuild: command not found` | CLT only, no Xcode.app | Run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| `xcodegen: command not found` | XcodeGen not installed | Run `brew install xcodegen` |
| `project.yml` not found | Wrong working directory | Ensure CI runs from repo root |
