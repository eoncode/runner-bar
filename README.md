# RunnerBar

> Live GitHub Actions and self-hosted runner monitoring in your macOS menu bar.

![Platform](https://img.shields.io/badge/macOS-13%2B-lightgrey?logo=apple)
![Swift](https://img.shields.io/badge/swift-5.9-orange?logo=swift)
![License](https://img.shields.io/github/license/eonist/runner-bar)

---

## Install

```bash
curl -fsSL https://eonist.github.io/runner-bar/install.sh | bash
```

Installs to `/Applications/RunnerBar.app`, clears Gatekeeper quarantine, and launches immediately.  
**Requires** [gh CLI](https://cli.github.com) installed and authenticated (`gh auth login`) on macOS 13+.

---

## Menu bar indicator

A single dot in your menu bar reflects your runners’ aggregate state:

| Dot | Meaning |
|:---:|---------|
| 🟢 | All runners online and idle |
| 🟡 | At least one runner busy |
| ⚫ | All runners offline, or none configured |

Click the dot to open the popover.

---

## Inside the popover

![RunnerBar screenshot](screenshot.png)

Four sections refresh automatically — runners and jobs every ~10 s, system stats every 2 s.

### 💻 System

Real-time CPU%, RAM (active + wired / total GB), and disk (used / total GB, free %).  
Data is read directly from Mach kernel APIs — no subprocesses, no `top`, no `df`.

### ⚡ Actions

The 5 most recent workflow run groups across your scopes, each grouped by commit or PR.  
Each row shows: status dot · PR `#n` or short SHA · commit title · active job name · job progress (`done/total`) · elapsed time.

Tap a row to drill down:

1. **Action detail** — job list for that commit/PR with per-job status and elapsed time
2. **Job detail** — step list with per-step status and duration
3. **Step log** — full raw log, copyable to clipboard

A **‹ back** chevron on each screen returns to the previous level. The popover resets to the main view on close.

### 🏃 Active Jobs

Up to 3 running or recently finished jobs across all scopes — name, status, conclusion, elapsed time.  
Tap any row for the same job → step → log drill-down.

### 🖥 Local Runners

All configured self-hosted runners with name and live status: **idle**, **busy**, or **offline**.

---

## Features

| Feature | Description |
|---------|-------------|
| **Log copy** | Copy logs to clipboard at action, job, or step level — paste into a terminal or LLM |
| **Re-run** | Re-run failed jobs for any workflow run group |
| **Cancel** | Cancel in-progress run groups |
| **Scopes** | Add / remove `owner/repo` or `org` scopes from inside the popover; persisted across restarts |
| **Launch at login** | Toggle directly in the popover — no System Settings needed |
| **Rate-limit banner** | Shown when the GitHub API quota is exhausted; polling pauses automatically |
| **Sign-in prompt** | Orange dot + button opens Terminal → `gh auth login` when unauthenticated |
| **Auto-poll** | Background refresh every ~10 s for runners and jobs |

---

## Requirements

| | |
|---|---|
| **OS** | macOS 13 Ventura or later · universal binary (arm64 + x86_64) |
| **Auth** | [gh CLI](https://cli.github.com) installed and authenticated |
| **Runners** | One or more self-hosted runners registered to repos or orgs you own |

---

## Documentation

| File | Description |
|------|-------------|
| [DEVELOPMENT.md](DEVELOPMENT.md) | Build and run locally with SwiftPM — no Xcode required |
| [DEPLOYMENT.md](DEPLOYMENT.md) | Release pipeline and GitHub Pages hosting |
| [AGENTS.md](AGENTS.md) | Context for AI coding agents working on this repo |
