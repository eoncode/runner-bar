# RunnerBar

> A macOS menu bar app that monitors your GitHub self-hosted runners and Actions workflow runs — without leaving your desktop.

![screenshot](screenshot.png)

---

## Install

```bash
curl -fsSL https://eonist.github.io/runner-bar/install.sh | bash
```

Installs to `/Applications/RunnerBar.app` and launches immediately. No Gatekeeper dialog — the installer bypasses quarantine by design. Requires [`gh`](https://cli.github.com) to be installed and authenticated (`gh auth login`).

---

## What it does

RunnerBar lives in your menu bar as a single colored dot that reflects your runners' aggregate state:

| Dot | Meaning |
|-----|---------|
| 🟢 Green | All configured runners online and idle |
| 🟡 Yellow | At least one runner busy |
| ⚫ Gray | All runners offline or none configured |

Click the dot to open a popover with four live sections:

### System
Real-time CPU%, RAM (active + wired GB / total GB), and disk (used / total GB, free%) — sampled every 2 seconds from Mach kernel APIs.

### Actions
The 5 most recent GitHub Actions workflow run groups for your configured scopes, grouped by commit/PR. Each row shows:
- Status dot (yellow = in-progress, green = success, red = failure, gray = queued/other)
- PR number or short SHA label
- Commit/PR title (≤ 40 chars)
- Current job name (while running)
- Job progress (e.g. `3/5`)
- Elapsed time

Tap a row to drill into the job list for that commit → tap a job to see its steps → tap a step to read its full log.

### Active Jobs
Up to 3 currently running or recently completed jobs across all scopes, with status, conclusion, and elapsed time. Tap to drill into step-level detail and logs.

### Local Runners
Your configured self-hosted runners with name and status (idle / busy / offline).

---

## Navigation

The popover has a 4-level drill-down:

```
Popover (main)
 ├── Actions → ActionDetailView (job list for a commit/PR)
 │     └── JobDetailView (steps)
 │           └── StepLogView (full log)
 └── Active Jobs → JobDetailView (steps)
                     └── StepLogView (full log)
```

A back-chevron at the top of each detail view returns you to the previous level. The popover resets to the main view on close.

---

## Features

- **Log copy** — copy logs to clipboard at three levels: action (all jobs), job (all steps), single step — paste straight into an LLM or terminal
- **Re-run** — re-run failed jobs for any workflow run group
- **Cancel** — cancel in-progress workflow run groups
- **Scopes** — add/remove `owner/repo` or `org` scopes directly from the popover; persisted in UserDefaults
- **Launch at login** — checkbox in the popover; no separate System Settings visit needed
- **Rate-limit banner** — visible warning when GitHub API quota is exhausted, with polling paused automatically
- **Sign in** — if `gh` is not authenticated, an orange dot + "Sign in with GitHub" button opens Terminal and runs `gh auth login`
- **Auto-poll** — runners and jobs refresh every ~10 seconds in the background

---

## Requirements

- macOS 13 Ventura or later (universal binary: arm64 + x86_64)
- [`gh` CLI](https://cli.github.com) installed and authenticated
- Self-hosted GitHub Actions runners registered to repos or orgs you own

---

## Docs

- [DEVELOPMENT.md](DEVELOPMENT.md) — build and run locally (SwiftPM only, no Xcode)
- [DEPLOYMENT.md](DEPLOYMENT.md) — release pipeline and GitHub Pages hosting
- [AGENTS.md](AGENTS.md) — context for AI coding agents
