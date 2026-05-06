# RunnerBar

> Live GitHub Actions and self-hosted runner monitoring in your macOS menu bar.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-lightgrey?logo=apple)
![Swift 5.9](https://img.shields.io/badge/swift-5.9-orange?logo=swift)
![License](https://img.shields.io/github/license/eonist/runner-bar)

---

## Install

```bash
curl -fsSL https://eonist.github.io/runner-bar/install.sh | bash
```

Installs to `/Applications/RunnerBar.app`, clears Gatekeeper quarantine, and launches immediately.  
**Requires** [gh CLI](https://cli.github.com) authenticated (`gh auth login`) on macOS 13+.

The menu bar dot reflects your runners’ aggregate state at a glance:

| Dot | Meaning |
|:---:|---------|
| 🟢 | All runners online and idle |
| 🟡 | At least one runner busy |
| ⚫ | All runners offline, or none configured |

Click the dot to open the popover.

---

## Inside the popover

![RunnerBar screenshot](screenshot.png)

Four live sections — runners and jobs refresh every ~10 s, system stats every 2 s.

---

### 💻 System

CPU%, RAM (active + wired GB / total GB), disk (used / total GB, free %).
Read directly from Mach kernel APIs — no subprocesses, no `top`, no `df`.

---

### ⚡ Actions

The 5 most recent workflow run groups across your scopes, grouped by commit or PR.

Each row: status dot · `#PR` or short SHA · commit title · active job name · progress (`done/total`) · elapsed time.

Tap a row to drill down:

1. **ActionDetailView** — full job list with per-job status and elapsed time
2. **JobDetailView** — step list with per-step status and duration
3. **StepLogView** — full raw log, copyable to clipboard

A **‹** back button on each screen returns to the previous level; the popover resets to main on close.

---

### 🏃 Active Jobs

Up to 3 running or recently finished jobs across all scopes — name, status, conclusion, elapsed time.
Tap any row for the same **JobDetailView → StepLogView** drill-down.

---

### 🖥 Local Runners

All configured self-hosted runners with name and live status: **idle**, **busy**, or **offline**.

---

## Features

| Feature | Description |
|---------|-------------|
| **Log copy** | Copy logs at action, job, or step granularity — paste into a terminal or LLM |
| **Re-run** | Re-run failed jobs for any workflow run group |
| **Cancel** | Cancel in-progress run groups |
| **Scopes** | Add / remove `owner/repo` or `org` scopes from inside the popover; persisted across restarts |
| **Launch at login** | Toggle in the popover — no System Settings needed |
| **Rate-limit banner** | Shown when the GitHub API quota is exhausted; polling pauses automatically |
| **Sign-in prompt** | Orange dot + button opens Terminal → `gh auth login` when unauthenticated |
| **Auto-poll** | Background refresh every ~10 s for runners and jobs |
| **Quit** | ⌘Q keyboard shortcut or Quit button in the popover footer |

---

## Requirements

- **macOS 13 Ventura+** — universal binary (arm64 + x86_64)
- **[gh CLI](https://cli.github.com)** — authenticated with access to your runners
- One or more self-hosted GitHub Actions runners on repos or orgs you own

---

## Documentation

| File | |
|------|-|
| [DEVELOPMENT.md](DEVELOPMENT.md) | *Build and run locally with SwiftPM — no Xcode required* |
| [DEPLOYMENT.md](DEPLOYMENT.md) | *Release pipeline and GitHub Pages hosting* |
| [AGENTS.md](AGENTS.md) | *Context for AI coding agents working on this repo* |
