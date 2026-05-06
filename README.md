# RunnerBar

> A lightweight macOS menu bar app that gives you a live view of your GitHub self-hosted runners and Actions workflow runs.

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey?logo=apple)
![Swift](https://img.shields.io/badge/swift-5.9-orange?logo=swift)
![License](https://img.shields.io/github/license/eonist/runner-bar)

![RunnerBar screenshot](screenshot.png)

---

## Install

```bash
curl -fsSL https://eonist.github.io/runner-bar/install.sh | bash
```

Requires [**gh CLI**](https://cli.github.com) installed and authenticated (`gh auth login`), macOS 13+.  
The script installs to `/Applications/RunnerBar.app`, clears Gatekeeper quarantine, and launches the app.

---

## How it works

RunnerBar sits in your menu bar as a single dot that reflects your runners’ aggregate state:

| &nbsp; | State |
|:------:|-------|
| 🟢 | All runners online and idle |
| 🟡 | At least one runner busy |
| ⚫ | All runners offline, or none configured |

Click the dot to open a popover with four live sections.

---

## Popover sections

### 💻 System
CPU%, RAM (active + wired GB / total GB), disk (used / total GB, free %) — sampled every 2 s directly from Mach kernel APIs. No subprocesses.

### ⚡️ Actions
The 5 most recent workflow run groups across your configured scopes, each grouped by commit or PR. Each row shows a status dot, PR number or short SHA, commit title, current job name (while running), job progress (`done/total`), and elapsed time.

Tap a row to drill in:
1. **Action detail** — full job list for that commit/PR, with per-job status and elapsed time
2. **Job detail** — all steps for that job, with per-step status and duration
3. **Step log** — full raw log for a single step, copyable to clipboard

### 🏃 Active Jobs
Up to 3 running or recently finished jobs across all scopes — name, status/conclusion, and elapsed time. Tap to open the same job/step/log drill-down.

### 🖥️ Local Runners
All configured self-hosted runners with name and live status (idle / busy / offline).

---

## Features

| Feature | What it does |
|---------|--------------|
| **Log copy** | Copy full logs to clipboard at action, job, or step granularity — ready to paste into a terminal or LLM |
| **Re-run** | Re-run failed jobs for any workflow run group |
| **Cancel** | Cancel in-progress run groups |
| **Scopes** | Add or remove `owner/repo` or `org` scopes from inside the popover; persisted across restarts |
| **Launch at login** | Toggle in the popover — no System Settings visit needed |
| **Rate-limit banner** | Warning banner when GitHub API quota is exhausted; polling pauses automatically |
| **Sign-in prompt** | Orange dot + “Sign in with GitHub” button runs `gh auth login` in Terminal when unauthenticated |
| **Auto-poll** | Runners and jobs refresh every ~10 s in the background |

---

## Requirements

- **macOS 13 Ventura or later** — universal binary (arm64 + x86_64)
- **[gh CLI](https://cli.github.com)** — authenticated with access to your runners
- One or more self-hosted GitHub Actions runners registered to repos or orgs you own

---

## Docs

| | |
|---|---|
| [DEVELOPMENT.md](DEVELOPMENT.md) | Build and run locally with SwiftPM — no Xcode required |
| [DEPLOYMENT.md](DEPLOYMENT.md) | Release pipeline and GitHub Pages hosting |
| [AGENTS.md](AGENTS.md) | Context for AI coding agents working on this repo |
