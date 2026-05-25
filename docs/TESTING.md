# UI Test Runner Setup

One-time manual steps required on the self-hosted Mac before UI tests will run unattended in CI.

## 1. Grant Accessibility permission to Xcode

Without this step, every CI run will block on a system dialog:

> **"XCTest is trying to Enable UI Automation. Touch ID or enter your password to allow this."**

This dialog cannot be dismissed programmatically and will cause the workflow to hang until it times out.

### Fix (do once on the runner machine)

1. Open **System Settings → Privacy & Security → Accessibility**
2. Click **+** and add the following:
   - `/Applications/Xcode.app`
   - `/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild`
3. Make sure the toggle next to both entries is **enabled** (blue)

Once granted, macOS remembers the permission permanently and the popup will never appear again during CI runs.

> **Note:** If you install a new major version of Xcode (e.g. upgrade from Xcode 26 to Xcode 27), you may need to re-grant permission for the new app bundle.

## 2. Confirm the runner has a GUI session

UI tests require a live WindowServer session. The GitHub Actions runner **must** be installed as a user launch agent (not a system daemon).

Verify by running on the runner machine:

```bash
ls ~/Library/LaunchAgents/com.github.runner.*.plist
```

If that file exists, you have a GUI session. If it's missing and the runner is under `/Library/LaunchDaemons/` instead, reinstall it:

```bash
sudo ./svc.sh uninstall
./svc.sh install
./svc.sh start
```
