# Agent Instructions

This file is context for AI coding agents. Read it before writing or editing any code.

---

## What this project is

A macOS menu bar app called **RunnerBar** that shows the status of GitHub self-hosted runners.
It lives in the menu bar as a colored dot. Click it to see a list of runners and their status.

---

## Hard constraints

- **No Xcode project** — do not generate `.xcodeproj`, `.xcworkspace`, `.xib`, or storyboard files
- **SwiftPM only** — `Package.swift` is the only build config
- **No third-party dependencies** unless absolutely necessary — prefer stdlib and system frameworks
- **No Interface Builder** — all UI is programmatic (AppKit + SwiftUI)
- **macOS 13+** minimum deployment target
- **Universal binary** — build for both arm64 and x86_64

---

## Build and run

```bash
# Develop
swift run

# Check for errors
swift build

# Release build + .app bundle
bash build.sh
```

Do not suggest opening Xcode or using `xcodebuild`.

---

## Project structure

```
Sources/RunnerBar/
├── main.swift        # NSApp bootstrap only
├── MenuBar.swift     # NSStatusItem, popover
├── GitHub.swift      # gh api calls, JSON parsing
└── Runners.swift     # Runner model, polling logic
```

Keep files small and single-responsibility. Add new files rather than growing existing ones.

---

## Auth

Never prompt the user for a token or PAT. Auth works like this:

```swift
// Shell out to gh CLI
let token = shell("gh auth token")
```

Fallback order:
1. `gh auth token` output
2. `GH_TOKEN` environment variable
3. `GITHUB_TOKEN` environment variable
4. If all fail: show message in popover — "Run `gh auth login` in Terminal"

---

## GitHub API

Use `gh api` shell-outs, not raw `URLSession` calls with manually managed auth headers.
This keeps auth, pagination, and GitHub host switching handled by the CLI.

```bash
# List runners for a repo
gh api /repos/{owner}/{repo}/actions/runners

# List runners for an org
gh api /orgs/{org}/actions/runners
```

Parse the JSON response with `Codable` structs.

---

## UI rules

- No Dock icon — `LSUIElement` is `true` in `Info.plist`
- Status icon in menu bar reflects aggregate runner state:
  - All online → green circle •
  - Some offline → yellow circle •
  - All offline / none configured → gray circle •
- Click icon → SwiftUI popover with runner list
- Each runner row: name, status badge (idle / active / offline), scope (repo or org)
- Refresh button + 30s auto-poll
- On first launch: text field to enter repo slugs (`owner/repo`) or org names to monitor
- Persist scope config in `UserDefaults`

---

## Shell helper

Use a simple synchronous shell helper for all CLI calls:

```swift
import Foundation

@discardableResult
func shell(_ command: String) -> String {
    let task = Process()
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    task.arguments = ["-c", command]
    task.launchPath = "/bin/zsh"
    task.launch()
    task.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                  encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
```

---

## What is out of scope (do not build)

- Registering or adding new runners
- Start / stop / restart runner processes
- launchctl integration
- Notifications
- Multi-account or multi-GitHub-host support
- Workflow run history or job logs
- Local process state detection (pgrep etc)

---

## When you are unsure

- Prefer the simpler implementation
- Prefer AppKit primitives over SwiftUI when SwiftUI requires macOS 14+
- Do not add features not listed here — ask first
