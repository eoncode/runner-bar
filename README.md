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

RunnerBar is a tiny macOS menu-bar app that shows whether your GitHub self-hosted runners are online. A colored dot summarizes state at a glance; click it to see each runner with an `idle` / `active` / `offline` badge. No Xcode, no Apple Developer account, no Gatekeeper dialog — one `curl` command installs it.

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

The installer downloads `RunnerBar.zip` from GitHub Pages, replaces any existing `/Applications/RunnerBar.app`, unzips the new bundle into `/Applications`, and launches it. The menu-bar dot appears immediately. See [DEPLOYMENT.md](DEPLOYMENT.md) for why Gatekeeper doesn't fire.

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
|:---:|---|
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
- **Runner list popover.** Each row shows the runner's name and a status badge — `idle`, `active`, or `offline`. See [`PopoverView.swift`](Sources/RunnerBar/PopoverView.swift).
- **In-popover sign-in.** If `gh` isn't authenticated, a **Sign in with GitHub** button opens Terminal running `gh auth login`. Otherwise you see a green "Authenticated" indicator.
- **Scopes managed in-app.** Add or remove `owner/repo` slugs and org names from the popover. Persisted in `UserDefaults`. See [`ScopeStore.swift`](Sources/RunnerBar/ScopeStore.swift).
- **30-second auto-polling.** A `Timer` in [`RunnerStore.swift`](Sources/RunnerBar/RunnerStore.swift) refreshes every configured scope in the background.
- **Launch at login.** One toggle, backed by `SMAppService` (macOS 13+). See [`LoginItem.swift`](Sources/RunnerBar/LoginItem.swift).
- **Menu-bar only.** `LSUIElement=true` in [Info.plist](Resources/Info.plist) — no Dock icon, no app-switcher entry.
- **Universal, tiny.** Single arm64 + x86_64 binary, ad-hoc signed by [`build.sh`](build.sh).

> **v0.1 is read-only.** RunnerBar shows state; it does not register, start, stop, or restart runners, and does not surface workflow logs. See [Out of scope](#-out-of-scope-for-v01).

<br/>

---

## 🚦 Status reference

**Menu-bar icon** — aggregate across all configured scopes, computed in [`RunnerStore.aggregateStatus`](Sources/RunnerBar/RunnerStore.swift):

| Color | Case | Meaning |
|:---:|---|---|
| 🟢 Green | `allOnline` | Every runner reports `status == "online"` |
| 🟠 Orange | `someOffline` | At least one runner is online, at least one isn't |
| 🔴 Red | `allOffline` | No runners are online, or no scopes are configured |

**Runner row badge** — per runner, rendered inline in [`PopoverView.swift`](Sources/RunnerBar/PopoverView.swift):

| Badge | Condition |
|---|---|
| `idle` | `status == "online"` and `busy == false` |
| `active` | `status == "online"` and `busy == true` |
| `offline` | anything else |

<br/>

---

## 🧾 Requirements

| | |
|---|---|
| **macOS** | 13 Ventura or later |
| **Architecture** | Apple Silicon or Intel (universal binary) |
| **[`gh` CLI](https://cli.github.com)** | Installed and authenticated (`brew install gh && gh auth login`) |

RunnerBar never stores a token. It resolves auth at runtime in this order — see [`Auth.swift`](Sources/RunnerBar/Auth.swift):

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
```

1. [`ScopeStore`](Sources/RunnerBar/ScopeStore.swift) stores the scopes you've added in `UserDefaults` under the key `scopes`.
2. [`RunnerStore`](Sources/RunnerBar/RunnerStore.swift) runs a `Timer` on a 30-second cadence; each tick fetches every scope on a background queue.
3. [`GitHub.swift`](Sources/RunnerBar/GitHub.swift) shells out to the `gh` CLI:
   - Scope contains `/` → `gh api /repos/{owner}/{repo}/actions/runners`
   - Otherwise → `gh api /orgs/{org}/actions/runners`
4. Responses decode into [`Runner`](Sources/RunnerBar/Runner.swift) values (`id`, `name`, `status`, `busy`).
5. `RunnerStore.aggregateStatus` collapses the combined list to `allOnline` / `someOffline` / `allOffline`, which drives the menu-bar icon via [`StatusIcon`](Sources/RunnerBar/StatusIcon.swift).

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
│   ├── RunnerMetrics.swift       # Local CPU/MEM via `ps` (model-layer helper)
│   ├── GitHub.swift              # `gh api` shell-outs
│   ├── ScopeStore.swift          # UserDefaults-backed scope list
│   ├── LoginItem.swift           # SMAppService launch-at-login
│   ├── Auth.swift                # Token resolution
│   └── Shell.swift               # shell() helper (zsh -c)
├── Resources/Info.plist          # LSUIElement=true, bundle metadata
├── build.sh                      # swift build → .app bundle → ad-hoc sign → zip
├── deploy.sh                     # push dist/ to gh-pages via git worktree
└── install.sh                    # curl | bash installer (also on gh-pages)
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

`build.sh` runs `swift build -c release --arch arm64 --arch x86_64`, assembles `dist/RunnerBar.app`, signs it ad-hoc, and produces `dist/RunnerBar.zip` + `dist/version.txt`. Details in [DEVELOPMENT.md](DEVELOPMENT.md); release flow in [DEPLOYMENT.md](DEPLOYMENT.md).

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
<summary><strong>I installed it but don't see anything.</strong></summary>

RunnerBar has no Dock icon (`LSUIElement=true`). Look for a small colored circle on the right side of your menu bar.
</details>

<details>
<summary><strong>Does it work with GitHub Enterprise Server?</strong></summary>

Not in v0.1. The `gh api` calls use default host resolution and multi-host support isn't implemented.
</details>

<details>
<summary><strong>Why is <code>gh</code> hard-coded to <code>/opt/homebrew/bin/gh</code>?</strong></summary>

Menu-bar apps launched via LaunchServices don't inherit a shell <code>PATH</code>, so the path is explicit in <a href="Sources/RunnerBar/Auth.swift"><code>Auth.swift</code></a> and <a href="Sources/RunnerBar/GitHub.swift"><code>GitHub.swift</code></a>. If <code>gh</code> lives elsewhere on your machine, symlink it there.
</details>

<br/>

---

## 🤝 Contributing

Conventions, mostly from [AGENTS.md](AGENTS.md):

- **SwiftPM only.** No `.xcodeproj`, `.xcworkspace`, `.xib`, or storyboards.
- **No third-party dependencies** unless there's a strong reason.
- **Programmatic UI only** (AppKit + SwiftUI).
- **Small, single-responsibility files.** Add a new file rather than growing an existing one.
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
| [DEVELOPMENT.md](DEVELOPMENT.md) | Local build, run, dev loop, auth during development |
| [DEPLOYMENT.md](DEPLOYMENT.md) | `build.sh`, `deploy.sh`, `gh-pages` layout, why Gatekeeper doesn't fire |
| [AGENTS.md](AGENTS.md) | Context and hard constraints for AI coding agents |

<br/>

---

<div align="center">
<sub>Built with SwiftPM · shipped with <code>curl | bash</code> · kept intentionally small.</sub>
</div>
