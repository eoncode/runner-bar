<div align="center">

<br/>

# RunnerBar

### GitHub self-hosted runner status, right in your macOS menu bar.

<br/>

[![Platform](https://img.shields.io/badge/macOS-13%2B-000000?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![Build](https://img.shields.io/badge/build-SwiftPM-2E7D32?style=flat-square&logo=swift&logoColor=white)](Package.swift)
[![Architecture](https://img.shields.io/badge/universal-arm64%20%2B%20x86__64-555555?style=flat-square)](build.sh)
[![Version](https://img.shields.io/badge/version-0.1.0-6A1B9A?style=flat-square)](https://eonist.github.io/runner-bar/version.txt)
[![Install](https://img.shields.io/badge/install-curl%20%7C%20bash-181717?style=flat-square&logo=gnubash&logoColor=white)](#-install)

<br/>

<img src="app.png" alt="RunnerBar screenshot — menu-bar dot and popover listing self-hosted runners" width="420"/>

<br/>

</div>

RunnerBar is a tiny macOS menu-bar app that shows whether your GitHub self-hosted runners are online. A colored dot summarizes state at a glance; click it for the full list with live CPU and memory for active runners. No Xcode, no Apple Developer account, no Gatekeeper dialog — one `curl` command installs it.

<br/>

## Table of contents

- [Install](#-install)
- [Getting started](#-getting-started)
- [Features](#-features)
- [Status reference](#-status-reference)
- [Requirements](#-requirements)
- [How it works](#-how-it-works)
- [Project layout](#-project-layout)
- [Build from source](#-build-from-source)
- [Out of scope for v0.1](#-out-of-scope-for-v01)
- [FAQ](#-faq)
- [Contributing](#-contributing)
- [Docs](#-docs)

<br/>

---

## 📦 Install

```bash
curl -fsSL https://eonist.github.io/runner-bar/install.sh | bash
```

The installer downloads `RunnerBar.zip` from GitHub Pages, unzips it to `/Applications`, and launches the app. The menu-bar dot appears immediately. See [DEPLOYMENT.md](DEPLOYMENT.md) for why Gatekeeper doesn't fire.

**Uninstall:**

```bash
rm -rf /Applications/RunnerBar.app
defaults delete dev.eonist.runnerbar 2>/dev/null || true
```

<br/>

---

## 🚀 Getting started

You'll be running in under a minute.

| Step | Action |
|---|---|
| 1 | `brew install gh && gh auth login` (once) |
| 2 | Install RunnerBar with the `curl` command above |
| 3 | Click the menu-bar dot to open the popover |
| 4 | Add a scope — `owner/repo` or a bare `org-name` |
| 5 | Done. RunnerBar polls every 30 seconds |

Optional: toggle **Launch at login** in the popover.

<br/>

---

## ✨ Features

- **Traffic-light menu-bar icon.** `systemGreen` when every runner is online, `systemOrange` when some are offline, `systemRed` when none are online or no scopes are configured. Drawn programmatically in [`StatusIcon.swift`](Sources/RunnerBar/StatusIcon.swift).
- **Runner list popover.** Each runner shows name, scope, and a status badge — `idle`, `active`, or `offline`. ([`PopoverView.swift`](Sources/RunnerBar/PopoverView.swift))
- **Live CPU & memory for active runners.** When a runner is busy, RunnerBar reads the local `Runner.Worker` process with `ps` and attaches CPU % / MEM %. ([`RunnerMetrics.swift`](Sources/RunnerBar/RunnerMetrics.swift))
- **In-popover sign-in.** If `gh` isn't authenticated, a **Sign in with GitHub** button opens Terminal running `gh auth login`. Otherwise you see a green "Authenticated" indicator.
- **Scopes managed in-app.** Add or remove `owner/repo` and org names from the popover. Persisted in `UserDefaults`. ([`ScopeStore.swift`](Sources/RunnerBar/ScopeStore.swift))
- **Launch at login.** One toggle, backed by `SMAppService` (macOS 13+). ([`LoginItem.swift`](Sources/RunnerBar/LoginItem.swift))
- **Menu-bar only.** `LSUIElement=true` — no Dock icon, no app-switcher entry.
- **Universal, tiny.** Single arm64 + x86_64 binary, ad-hoc signed.

> **v0.1 is read-only.** RunnerBar shows state; it does not register, start, stop, or restart runners, and does not surface workflow logs. See [Out of scope](#-out-of-scope-for-v01).

<br/>

---

## 🚦 Status reference

**Menu-bar icon** — aggregate across all scopes:

| Color | Meaning | Source |
|:-:|---|---|
| 🟢 Green | Every runner is `online` | `AggregateStatus.allOnline` |
| 🟠 Orange | At least one runner is `online`, at least one isn't | `AggregateStatus.someOffline` |
| 🔴 Red | No runners are `online`, or no scopes are configured | `AggregateStatus.allOffline` |

**Runner row badge** — per runner, inside the popover:

| Badge | Meaning |
|---|---|
| `idle` | Runner is `online` and not currently executing a job |
| `active` | Runner is `online` and `busy` (shows CPU / MEM when a local `Runner.Worker` is found) |
| `offline` | Runner's `status` is not `online` |

<br/>

---

## 🧾 Requirements

| | |
|---|---|
| **macOS** | 13 Ventura or later |
| **Architecture** | Apple Silicon or Intel (universal) |
| **[`gh` CLI](https://cli.github.com)** | Installed and authenticated |

RunnerBar never stores a token. It resolves auth at runtime in this order ([`Auth.swift`](Sources/RunnerBar/Auth.swift)):

1. `gh auth token`
2. `GH_TOKEN` environment variable
3. `GITHUB_TOKEN` environment variable

<br/>

---

## 🧠 How it works

```text
 menu-bar dot  ◀── StatusIcon  ◀── RunnerStore.aggregateStatus
                                         ▲
                                         │  30s Timer
                                         │
                                    GitHub.swift  ◀── ScopeStore (UserDefaults)
                                         │
                                    gh api /repos/{owner}/{repo}/actions/runners
                                    gh api /orgs/{org}/actions/runners
                                         │
                                    [Runner] (id, name, status, busy)
                                         │
                                    busy?  ──▶  RunnerMetrics via `ps`
```

- [`ScopeStore`](Sources/RunnerBar/ScopeStore.swift) holds the scopes you've added, persisted in `UserDefaults`.
- [`RunnerStore`](Sources/RunnerBar/RunnerStore.swift) runs a `Timer` on a 30-second cadence. Each tick fetches every scope in the background.
- [`GitHub.swift`](Sources/RunnerBar/GitHub.swift) shells out to `gh api`: `/repos/{owner}/{repo}/actions/runners` if the scope contains `/`, otherwise `/orgs/{org}/actions/runners`.
- Responses decode into [`Runner`](Sources/RunnerBar/Runner.swift) values.
- For `busy` runners, [`RunnerMetrics`](Sources/RunnerBar/RunnerMetrics.swift) runs `ps -eo pcpu,pmem,args | grep Runner.Worker` locally and matches on runner name.
- `RunnerStore.aggregateStatus` collapses the list to `allOnline` / `someOffline` / `allOffline`, which drives the menu-bar dot.

<br/>

---

## 🗂 Project layout

```text
runner-bar/
├── Package.swift                 # SwiftPM manifest — the only build config
├── Sources/RunnerBar/
│   ├── main.swift                # NSApp bootstrap
│   ├── AppDelegate.swift         # NSStatusItem + NSPopover wiring
│   ├── StatusIcon.swift          # Traffic-light dot
│   ├── PopoverView.swift         # SwiftUI popover UI
│   ├── RunnerStore.swift         # 30s polling + aggregate status
│   ├── Runner.swift              # Runner model
│   ├── RunnerMetrics.swift       # CPU/MEM via `ps`
│   ├── GitHub.swift              # `gh api` shell-outs
│   ├── ScopeStore.swift          # UserDefaults-backed scope list
│   ├── LoginItem.swift           # SMAppService launch-at-login
│   ├── Auth.swift                # Token resolution
│   └── Shell.swift               # shell() helper
├── Resources/Info.plist          # LSUIElement=true
├── build.sh                      # compile → .app → ad-hoc sign → zip
├── deploy.sh                     # push dist/ to gh-pages
└── install.sh                    # curl | bash installer
```

<br/>

---

## 🛠 Build from source

SwiftPM only — no Xcode project, no Interface Builder.

```bash
git clone https://github.com/eonist/runner-bar
cd runner-bar
swift run          # develop
swift build        # fast error check
bash build.sh      # universal release .app in ./dist
```

Details in [DEVELOPMENT.md](DEVELOPMENT.md); release flow in [DEPLOYMENT.md](DEPLOYMENT.md).

<br/>

---

## 🚧 Out of scope for v0.1

Not in the app, not planned for v0.1:

- Registering or adding new runners
- Starting / stopping / restarting runner processes
- Workflow run history or job logs
- Desktop notifications
- Multi-account or GitHub Enterprise Server support

Full spec: [issue #1](https://github.com/eonist/runner-bar/issues/1). What's next: [open issues](https://github.com/eonist/runner-bar/issues).

<br/>

---

## ❓ FAQ

<details>
<summary><strong>Do I need a Personal Access Token?</strong></summary>

No. RunnerBar reuses whatever session `gh auth login` created. To pin a specific token, export `GH_TOKEN` or `GITHUB_TOKEN` before launching.
</details>

<details>
<summary><strong>The popover says "Sign in with GitHub" but I'm already signed into github.com.</strong></summary>

Auth comes from the `gh` CLI, not the browser. Run `brew install gh && gh auth login`.
</details>

<details>
<summary><strong>Why are CPU / MEM values missing on an active runner?</strong></summary>

[`RunnerMetrics`](Sources/RunnerBar/RunnerMetrics.swift) reads local processes only. If the busy runner is on a different Mac, or its worker process isn't named `Runner.Worker`, `ps` can't find it and the row falls back to `active`.
</details>

<details>
<summary><strong>I installed it but don't see anything.</strong></summary>

RunnerBar has no Dock icon (`LSUIElement=true`). Look for a colored circle on the right side of your menu bar.
</details>

<details>
<summary><strong>Does it work with GitHub Enterprise Server?</strong></summary>

Not in v0.1.
</details>

<details>
<summary><strong>Why is <code>gh</code> hard-coded to <code>/opt/homebrew/bin/gh</code>?</strong></summary>

Menu-bar apps launched via LaunchServices don't inherit a shell `PATH`, so the path is explicit. If `gh` is elsewhere, symlink it there.
</details>

<br/>

---

## 🤝 Contributing

Conventions, mostly from [AGENTS.md](AGENTS.md):

- **SwiftPM only.** No `.xcodeproj`, `.xcworkspace`, `.xib`, or storyboards.
- **No third-party dependencies** unless there's a strong reason.
- **Programmatic UI only** (AppKit + SwiftUI).
- **Small, single-responsibility files.** Add a new file rather than growing one.
- **macOS 13+**, universal binary.

```bash
git clone https://github.com/eonist/runner-bar
cd runner-bar
swift run
```

<br/>

---

## 📚 Docs

| Doc | What's inside |
|---|---|
| [DEVELOPMENT.md](DEVELOPMENT.md) | Local build, run, dev loop |
| [DEPLOYMENT.md](DEPLOYMENT.md) | `build.sh`, `deploy.sh`, `gh-pages` layout |
| [AGENTS.md](AGENTS.md) | Context for AI coding agents |

<br/>

---

<div align="center">
<sub>Built with SwiftPM · shipped with <code>curl | bash</code> · kept intentionally small.</sub>
</div>
