# RunnerBar

> macOS menu bar app — monitor GitHub self-hosted runners and Actions workflow runs without leaving your desktop.

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey?logo=apple)
![Swift](https://img.shields.io/badge/swift-5.9-orange?logo=swift)
![License](https://img.shields.io/github/license/eonist/runner-bar)

![screenshot](screenshot.png)

---

## Quick Start

**Prerequisites**
- macOS 13 Ventura or later
- [`gh` CLI](https://cli.github.com) installed and authenticated (`gh auth login`)

```bash
curl -fsSL https://eonist.github.io/runner-bar/install.sh | bash
```

Installs to `/Applications/RunnerBar.app`, bypasses Gatekeeper quarantine, and launches immediately.

---

## Menu bar dot

RunnerBar shows a single dot in your menu bar at all times:

| Dot | State |
|:---:|-------|
| 🟢 | All runners online and idle |
| 🟡 | At least one runner busy |
| ⚫ | All runners offline, or none configured |

Click the dot to open the popover.

---

## Popover

The popover has four live sections, refreshed every ~10 seconds (system stats every 2 s).

### 💻 System
CPU utilisation, RAM in use (active + wired / total), and disk (used / total, free %) — read directly from Mach kernel APIs, no subprocesses.

### ⚡ Actions
The 5 most recent workflow run groups across your scopes, grouped by commit or PR:

| Column | Content |
|--------|---------|
| Dot | yellow = running · green = success · red = failure · gray = queued |
| Label | PR `#123` or short SHA |
| Title | Commit / PR title (truncated) |
| Job | Current job name (while running) |
| Progress | `3/5` jobs concluded |
| Elapsed | Wall-clock time since run started |

Tap any row → job list for that run → tap a job → step list → tap a step → full log.

### 🏃 Active Jobs
Up to 3 currently running or recently finished jobs across all scopes — status, conclusion, and elapsed time. Tap to drill into steps and logs.

### 🖥 Local Runners
Your self-hosted runners with name and live status (idle / busy / offline).

---

## Navigation

```
Popover (main)
├── Actions row   →  ActionDetailView  (job list for a commit/PR)
│                        └── JobDetailView  (step list)
│                                └── StepLogView  (full log)
└── Active Job row →  JobDetailView  (step list)
                             └── StepLogView  (full log)
```

Every detail view has a **‹ back** button. The popover always resets to the main view on close.

---

## Features

| | Feature | Detail |
|---|---------|--------|
| 📋 | **Log copy** | Copy logs to clipboard at three granularities: full action, single job, single step — paste into a terminal or LLM |
| 🔁 | **Re-run** | Re-run failed jobs for any workflow run group |
| 🛑 | **Cancel** | Cancel in-progress run groups |
| 🔭 | **Scopes** | Add/remove `owner/repo` or `org` scopes from the popover; persisted across restarts |
| 🚀 | **Launch at login** | Toggle directly in the popover — no System Settings needed |
| ⚠️ | **Rate-limit banner** | Shown when GitHub API quota is exhausted; polling pauses automatically |
| 🔑 | **Sign in** | Orange dot + button opens Terminal → `gh auth login` when unauthenticated |

---

## Requirements

- macOS 13 Ventura or later · universal binary (arm64 + x86_64)
- [`gh` CLI](https://cli.github.com) authenticated with access to your runners
- One or more self-hosted GitHub Actions runners registered to repos or orgs you own

---

## Docs

| File | Purpose |
|------|---------|
| [DEVELOPMENT.md](DEVELOPMENT.md) | Build and run locally with SwiftPM (no Xcode required) |
| [DEPLOYMENT.md](DEPLOYMENT.md) | Release pipeline and GitHub Pages hosting |
| [AGENTS.md](AGENTS.md) | Context file for AI coding agents |
