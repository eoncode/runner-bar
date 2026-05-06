# RunnerBar

> **Self-hosted GitHub Actions runners, at a glance in your macOS menu bar.**

[![SwiftLint](https://github.com/eoncode/runner-bar/actions/workflows/swiftlint.yml/badge.svg)](https://github.com/eoncode/runner-bar/actions/workflows/swiftlint.yml)

![screenshot.png](screenshot.png)
 
---

## The Problem

1. **Status Visibility** – It's often hard to tell at a glance if your self-hosted GitHub runners are online, idle, or busy without digging into the GitHub Settings UI.
2. **Management Friction** – Managing multiple runners across different repositories or organizations can be cumbersome, especially when you need to quickly identify which ones are installed where.
3. **Activity Tracking** – Troubleshooting failed CI/CD jobs usually requires navigating several layers of the GitHub web interface to find the relevant logs and error messages.

---

## The Solution

1. **At-a-Glance Status** – A dedicated menu bar icon that reflects the aggregate state of all your runners (Online, Offline, or Busy).
2. **Centralized Management** – Easily monitor and manage runners from multiple repo and organization scopes in one unified list.
3. **Deep Activity Insights** – Quickly browse through recent action sessions, drill down into individual jobs, and view live step logs directly within the app.

## Features
- **Real-time Monitoring** – Auto-polls the GitHub API every 30 seconds to keep your runner status up to date.
- **Multi-Scope Support** – Monitor runners for specific repositories (`owner/repo`) or entire organizations.
- **Smart Log Export** – Copy action logs to the clipboard at any level: entire actions, specific jobs, or individual steps—perfect for quick debugging with LLMs.
- **Interactive Control** – Re-run failed jobs or cancel active sessions directly from the menu bar.
- **Deep Inspection** – View detailed job metadata, including workflow YML snippets and commit SHAs.
- **System Stats** – Integrated view of local system resource usage (CPU/Memory) to see how runners impact your machine.

## Install

To install RunnerBar, simply run the following command in your terminal:

```bash
curl -fsSL https://eonist.github.io/runner-bar/install.sh | bash
```

Alternatively, you can download the latest `.zip` from the [releases page](https://github.com/eoncode/runner-bar/releases) and move `RunnerBar.app` to your `/Applications` folder.

---

## Usage

1. **Authentication** – RunnerBar uses the GitHub CLI (`gh`) for authentication. Ensure you have it installed and are logged in (`gh auth login`).
2. **Configuration** – On first launch, click the menu bar icon and enter the repository slugs (e.g., `eoncode/runner-bar`) or organization names you wish to monitor.
3. **Navigation** – Click the colored status dot in your menu bar to open the popover. From there, you can drill down into specific jobs and logs.

---

## Development

Detailed guides for contributors:

- [DEVELOPMENT.md](DEVELOPMENT.md) — How to build and run locally.
- [DEPLOYMENT.md](DEPLOYMENT.md) — How releases are built and deployed.
- [AGENTS.md](AGENTS.md) — Context and rules for AI coding agents.

### Quick Build & Test

To build the app and run it immediately:

```bash
bash build.sh && pkill RunnerBar; sleep 1 && open dist/RunnerBar.app
```

To test a specific branch:

```bash
git fetch && git checkout <branch-name> && git pull
bash build.sh && pkill RunnerBar; sleep 1 && open dist/RunnerBar.app
```

---

## Architecture

RunnerBar is built with **SwiftUI** and **AppKit**, following a lightweight and performant architecture:

- **SwiftPM Only** – No Xcode projects or workspaces. `Package.swift` is the single source of truth for builds.
- **Zero Third-party Dependencies** – Leverages Apple's system frameworks and the GitHub CLI for a minimal footprint.
- **Shell-out Strategy** – Uses `gh api` for all GitHub interactions, ensuring secure auth and seamless host switching.
- **Universal Binary** – Built to run natively on both Intel and Apple Silicon Macs.

For a deep dive into the popover sizing logic and navigation stack, see the extensive comments in `AppDelegate.swift`.

---

## Contributing

Contributions are welcome! If you find a bug or have a feature request, please open an issue. If you'd like to contribute code:

1. Fork the repository.
2. Create a feature branch.
3. Ensure your code follows the existing style (we use `SwiftLint`).
4. Submit a pull request.

Please read [AGENTS.md](AGENTS.md) for specific coding standards and constraints.
