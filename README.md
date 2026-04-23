# RunnerBar

A macOS menu bar app that shows the status of your GitHub self-hosted runners at a glance.

> No Xcode. No Apple Developer account. No Gatekeeper dialogs. One `curl` command to install.

![RunnerBar screenshot](https://github.com/eonist/runner-bar/assets/11816788/runnerbar-screenshot.png)

---

## The problem

You have self-hosted runners installed on your Mac. You have no idea if they're online, offline, or busy without navigating to GitHub.com. RunnerBar fixes that — a colored dot in your menu bar tells you instantly.

- 🟢 All runners online
- 🟡 Some runners offline  
- ⚫ All offline or none configured

Click the dot to see a full list of runners with their name, status, and repo/org scope.

---

## Install

```bash
curl -fsSL https://eonist.github.io/runner-bar/install.sh | bash
```

That's it. No Gatekeeper dialog, no System Settings, no Apple ID.

---

## Requirements

- macOS 13+
- [`gh` CLI](https://cli.github.com) installed and authenticated (`gh auth login`)

RunnerBar uses your existing `gh` CLI session for auth — no PAT, no OAuth setup.

---

## How it works

1. On first launch, enter one or more repo slugs (`owner/repo`) or org names to monitor
2. RunnerBar polls the GitHub API every 30 seconds via `gh api`
3. The menu bar icon updates based on aggregate runner state
4. Click the icon to see the full runner list and refresh manually

---

## v0.1 scope

RunnerBar v0.1 is intentionally minimal — read-only visibility only.

Out of scope for v0.1:
- Registering or adding new runners
- Starting / stopping runner processes
- Notifications
- Multi-account support

See [issue #1](https://github.com/eonist/runner-bar/issues/1) for the full spec.

---

## Docs

- [DEVELOPMENT.md](DEVELOPMENT.md) — how to build and run locally
- [DEPLOYMENT.md](DEPLOYMENT.md) — how releases are built and deployed
- [AGENTS.md](AGENTS.md) — context for AI coding agents

---

## Contributing

This project is built with SwiftPM and edited with AI assistance — no Xcode required.

```bash
git clone https://github.com/eonist/runner-bar
cd runner-bar
swift run
```

See [DEVELOPMENT.md](DEVELOPMENT.md) for the full dev setup.
