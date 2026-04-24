<div align="center">

# RunnerBar

**Keep an eye on your GitHub self-hosted runners — right from the macOS menu bar.**

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](https://developer.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![Build](https://img.shields.io/badge/build-SwiftPM-success?logo=swift)](Package.swift)
[![Arch](https://img.shields.io/badge/arch-universal%20(arm64%20%2B%20x86__64)-lightgrey)](build.sh)
[![Version](https://img.shields.io/badge/version-0.1.0-blueviolet)](https://eonist.github.io/runner-bar/version.txt)
[![Install](https://img.shields.io/badge/install-curl%20%7C%20bash-black?logo=gnubash&logoColor=white)](#install)

<br/>

![RunnerBar screenshot](https://raw.githubusercontent.com/eonist/runner-bar/main/app.png)

<sub>A single colored dot in your menu bar tells you whether every self-hosted runner is online, some are offline, or nothing is responding. Click it for the details.</sub>

</div>

---

## Why RunnerBar

You run self-hosted GitHub Actions runners on your Mac. Without RunnerBar, the only way to check whether they are actually online is to open a browser, log into GitHub, and click through to **Settings → Actions → Runners** for every repo or org you care about.

RunnerBar collapses that workflow into a glance at the menu bar:

- **At a glance** — one colored dot summarizes the state of every runner you monitor.
- **No browser, no tabs** — the popover lists each runner with its name, status and CPU/MEM usage.
- **No Apple account, no Xcode, no Gatekeeper dialog** — a single `curl` command installs a signed `.app` into `/Applications`.
- **No new credentials** — reuses your existing [`gh`](https://cli.github.com) CLI session. No PAT to create, no OAuth app to register.

---

## Features

- 🟢🟠🔴 **Traffic‑light menu bar icon** — `systemGreen` when every runner is online, `systemOrange` when some are offline, `systemRed` when all are offline or no scopes are configured. Rendered programmatically in `StatusIcon.swift` so it stays crisp on any display.
- 📋 **Runner list popover** — every runner you monitor with its name and a status badge (`idle` / `active` / `offline`).
- 📊 **Local CPU & memory for active runners** — when a runner is busy, RunnerBar looks up its local `Runner.Worker` process via `ps` and computes live CPU % / MEM %.
- 🔐 **Auth status indicator** — a green dot with "Authenticated" when `gh` is ready, or a tappable "Sign in with GitHub" button that opens Terminal running `gh auth login`.
- ➕ **Scope management in‑app** — add or remove `owner/repo` slugs and org names directly from the popover. Persisted in `UserDefaults`.
- 🔁 **30‑second auto‑polling** — scopes are refreshed every 30 s via `gh api`. No manual refresh needed.
- 🚀 **Launch at login** — one‑click toggle backed by `SMAppService` (macOS 13+ LoginItem API).
- 🕶 **Menu‑bar only** — `LSUIElement=true` in `Info.plist`, so there's no Dock icon and no app switcher entry.
- 📦 **Single universal binary** — ~a few MB, arm64 + x86_64, ad‑hoc signed for Apple Silicon.

> **v0.1 is read‑only on purpose.** RunnerBar shows runner state. It does **not** register, start, stop, or restart runner processes, and does not surface workflow logs. See [Out of scope](#out-of-scope-for-v01) below.

---

## Install

One command, no Gatekeeper dialog, no System Settings trip:

```bash
curl -fsSL https://eonist.github.io/runner-bar/install.sh | bash
```

What it does:

1. Downloads `RunnerBar.zip` from [eonist.github.io/runner-bar](https://eonist.github.io/runner-bar/).
2. Unzips `RunnerBar.app` into `/Applications`.
3. Launches it — the menu bar dot appears immediately.

**Why no Gatekeeper warning?** Files downloaded with `curl` don't get the `com.apple.quarantine` extended attribute, which is what triggers Gatekeeper. The ad‑hoc‑signed app lands in `/Applications` and opens clean. See [DEPLOYMENT.md](DEPLOYMENT.md) for the full details.

### Uninstall

```bash
rm -rf /Applications/RunnerBar.app
defaults delete dev.eonist.runnerbar 2>/dev/null || true
```

---

## Requirements

| | |
|---|---|
| **macOS** | 13 Ventura or later |
| **Architecture** | Apple Silicon or Intel (universal binary) |
| **[`gh` CLI](https://cli.github.com)** | Installed and authenticated: `brew install gh && gh auth login` |

RunnerBar does not store a token. It shells out to `gh auth token` at runtime, with fallback to the `GH_TOKEN` and `GITHUB_TOKEN` environment variables if you prefer to scope a specific token to the app.

---

## Getting started

1. **Install** with the `curl` command above.
2. **Click the dot** in the menu bar to open the popover.
3. **Sign in** — if `gh` isn't authenticated, the popover shows a "Sign in with GitHub" button that launches Terminal and runs `gh auth login` for you.
4. **Add a scope** — type an `owner/repo` slug (for a repo‑level runner) or a bare org name (for an org‑level runner) into the **Scopes** field and press `+`. Add as many as you like.
5. **Done.** The icon now reflects the aggregate state of every runner across every scope. It refreshes every 30 seconds.

Optionally, toggle **Launch at login** in the popover so RunnerBar is always there after a reboot.

---

## How it works

```
                          ┌──────────────────────┐
  menu bar dot  ◀─────────┤  StatusIcon (AppKit) │
                          └──────────▲───────────┘
                                     │ aggregate status
                          ┌──────────┴───────────┐
                          │     RunnerStore      │   30s Timer
                          │  (singleton + poll)  │◀─────────
                          └──────────▲───────────┘
                                     │ [Runner]
                          ┌──────────┴───────────┐
                          │      GitHub.swift    │
                          │   `gh api /...`      │
                          └──────────▲───────────┘
                                     │ scopes
                          ┌──────────┴───────────┐
                          │   ScopeStore         │
                          │  (UserDefaults)      │
                          └──────────────────────┘
```

1. `ScopeStore` holds the list of scopes you've added, persisted in `UserDefaults`.
2. `RunnerStore` runs a `Timer` on a 30‑second cadence; each tick dispatches a background fetch per scope.
3. `GitHub.swift` shells out to the `gh` CLI:
   - For a scope containing `/` → `gh api /repos/{owner}/{repo}/actions/runners`
   - Otherwise → `gh api /orgs/{org}/actions/runners`
4. JSON is decoded into `Runner` values (`id`, `name`, `status`, `busy`).
5. For runners flagged `busy`, `RunnerMetrics` runs `ps -eo pcpu,pmem,args | grep Runner.Worker` locally and matches on the runner's name to attach live CPU / MEM percentages.
6. `RunnerStore.aggregateStatus` collapses the list to one of `allOnline` / `someOffline` / `allOffline`, which drives the menu‑bar dot.

Auth is resolved lazily each call via `Auth.swift`, in this order:

1. `gh auth token` output
2. `GH_TOKEN` environment variable
3. `GITHUB_TOKEN` environment variable
4. If none are available, the popover shows a **Sign in with GitHub** button.

---

## Project layout

```
runner-bar/
├── Package.swift                 # SwiftPM manifest — the only build config
├── Sources/RunnerBar/
│   ├── main.swift                # NSApp bootstrap
│   ├── AppDelegate.swift         # NSStatusItem + NSPopover wiring
│   ├── StatusIcon.swift          # Draws the traffic-light dot
│   ├── PopoverView.swift         # SwiftUI popover UI
│   ├── RunnerStore.swift         # 30s polling + aggregate status
│   ├── Runner.swift              # Runner model + display helpers
│   ├── RunnerMetrics.swift       # CPU/MEM via `ps` for Runner.Worker
│   ├── GitHub.swift              # `gh api` shell-outs + JSON decode
│   ├── ScopeStore.swift          # UserDefaults-backed scope list
│   ├── LoginItem.swift           # Launch at login via SMAppService
│   ├── Auth.swift                # gh CLI / env var token resolution
│   └── Shell.swift               # Synchronous shell() helper
├── Resources/Info.plist          # LSUIElement=true, bundle metadata
├── build.sh                      # compile → .app → ad-hoc sign → zip
├── deploy.sh                     # push dist/ to gh-pages
└── install.sh                    # curl|bash installer (also on gh-pages)
```

---

## Build from source

No Xcode, no `.xcodeproj`, no Interface Builder — [SwiftPM](https://swift.org/package-manager/) only.

```bash
git clone https://github.com/eonist/runner-bar
cd runner-bar
swift run                 # develop & run
swift build               # fast error check
bash build.sh             # universal release .app bundle in ./dist
```

Full development setup and dependency story in [DEVELOPMENT.md](DEVELOPMENT.md). Release and `gh-pages` distribution flow in [DEPLOYMENT.md](DEPLOYMENT.md).

---

## Out of scope for v0.1

RunnerBar v0.1 is deliberately small. The following are **not** in the app and are not planned for v0.1:

- Registering or adding new runners
- Starting / stopping / restarting runner processes (no `launchctl` integration)
- Workflow run history or job logs
- Desktop notifications
- Multi‑account or multi‑GitHub‑host (GHES) support

See [issue #1](https://github.com/eonist/runner-bar/issues/1) for the full v0.1 specification and [open issues](https://github.com/eonist/runner-bar/issues) for what's next.

---

## FAQ

**Does this require a GitHub Personal Access Token?**
No. It reuses whatever session `gh auth login` created. If you'd rather pin a specific token, export `GH_TOKEN` or `GITHUB_TOKEN` before launching the app.

**Why does the popover show "Sign in with GitHub" when I'm already signed into the GitHub website?**
Auth comes from the `gh` CLI, not the browser. Install [`gh`](https://cli.github.com) with `brew install gh` and run `gh auth login`.

**Where does the CPU / MEM reading come from?**
`RunnerMetrics` locates the runner's `Runner.Worker` process on the local machine with `ps -eo pcpu,pmem,args | grep Runner.Worker` and matches on the runner's name. If the busy runner lives on a different Mac — or the worker process name doesn't match — `ps` won't find it and no metrics are computed.

**I installed the app but nothing appears.**
RunnerBar has no Dock icon on purpose (`LSUIElement=true`). Look at the right side of your menu bar for a colored circle. If you still don't see it, your menu bar may be full — try hiding other items or using a menu‑bar manager.

**Does it work with GitHub Enterprise Server?**
Not in v0.1. Multi‑host support is out of scope for the first release.

**Why is `gh` hard‑coded to `/opt/homebrew/bin/gh`?**
That's the Homebrew install path on Apple Silicon. Menu‑bar apps launched via LaunchServices don't inherit a shell `PATH`, so the path is explicit. If you installed `gh` elsewhere, symlink or copy it to `/opt/homebrew/bin/gh`.

---

## Contributing

Contributions are welcome. A few conventions, mostly borrowed from [AGENTS.md](AGENTS.md):

- **SwiftPM only.** Do not add an Xcode project, workspace, storyboards, or `.xib` files.
- **No third‑party dependencies** unless there's a strong reason.
- **Programmatic UI only** (AppKit + SwiftUI) — no Interface Builder.
- **Small, single‑responsibility files.** Add a new file rather than growing an existing one.
- **macOS 13+** is the minimum deployment target; universal binary is the shipping artifact.

To get going:

```bash
git clone https://github.com/eonist/runner-bar
cd runner-bar
swift run
```

See [DEVELOPMENT.md](DEVELOPMENT.md) for the full loop.

---

## Docs

- [DEVELOPMENT.md](DEVELOPMENT.md) — local build, run, dev loop, auth during development
- [DEPLOYMENT.md](DEPLOYMENT.md) — `build.sh`, `deploy.sh`, `gh-pages` layout, why Gatekeeper doesn't fire
- [AGENTS.md](AGENTS.md) — context and constraints for AI coding agents

---

<div align="center">
<sub>Built with SwiftPM, shipped with <code>curl | bash</code>, and kept intentionally small.</sub>
</div>
