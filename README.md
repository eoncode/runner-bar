# RunnerBar 

**Platform & Stack**

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple&logoColor=white)
![Apple Silicon Only](https://img.shields.io/badge/Apple_Silicon-arm64_only-000000?logo=apple&logoColor=white)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![SPM 6.2](https://img.shields.io/badge/SPM-6.2-F05138?logo=swift&logoColor=white)
![Liquid Glass](https://img.shields.io/badge/UI-Liquid%20Glass-0A84FF?style=flat-square&logo=apple&logoColor=white)

**CI Checks**

![UI Tests](https://github.com/eoncode/runner-bar/actions/workflows/ui-tests.yml/badge.svg)
![Unit Tests](https://github.com/eoncode/runner-bar/actions/workflows/swift-test.yml/badge.svg)
![SwiftLint](https://github.com/eoncode/runner-bar/actions/workflows/swiftlint.yml/badge.svg)
![Periphery](https://github.com/eoncode/runner-bar/actions/workflows/periphery.yml/badge.svg)
[![CodeQL](https://github.com/eoncode/runner-bar/actions/workflows/codeql.yml/badge.svg)](https://github.com/eoncode/runner-bar/actions/workflows/codeql.yml)

**AI Reviewers**

[![Greptile](https://img.shields.io/badge/🦎%20AI%20Review-Greptile-6C47FF?logoColor=white)](https://greptile.com)
[![CodeRabbit](https://img.shields.io/badge/🐰%20AI%20Review-CodeRabbit-FF6B35?logoColor=white)](https://coderabbit.ai)
[![Octopus Review](https://img.shields.io/badge/🐙%20AI%20Review-Octopus-00B4D8?logoColor=white)](https://octopusreview.com)

**Code Quality**

[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Reliability Rating](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=reliability_rating)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Security Rating](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=security_rating)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Maintainability Rating](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=sqale_rating)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Technical Debt](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=sqale_index)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Bugs](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=bugs)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Vulnerabilities](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=vulnerabilities)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Code Smells](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=code_smells)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Duplicated Lines (%)](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=duplicated_lines_density)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)
[![Lines of Code](https://sonarcloud.io/api/project_badges/measure?project=eoncode_runner-bar&metric=ncloc)](https://sonarcloud.io/summary/new_code?id=eoncode_runner-bar)


> GitHub Actions, local runners, and AI failure recovery — in your macOS menu bar.

<img src="scrnsht.png" width="100%" alt="RunnerBar screenshot" />

---

## Features

**🚦 Workflow status**
- Live run status across all your repos and orgs
- Drill into jobs and steps, copy logs at any level
- Re-run, re-run failed, or cancel from the popover
- Right-click a run to copy YAML, SHA, or open in browser

**🏃 Local runner manager**
- Auto-discovers runners on this Mac (LaunchAgents, `.runner` files, launchctl)
- Start, stop, add, and remove runners without touching Terminal or github.com

**🪝 Failure hooks**
- When a run fails, automatically fire a shell command in Terminal
- Tokens like `$FAILURE_LOG`, `$LOCAL_PATH`, `$BRANCH`, `$RUN_LINK` are substituted before the command runs
- Default: `cd $LOCAL_PATH && gemini -p '$FAILURE_LOG' --model=gemini-2.5-flash --approval-mode=yolo`
- Optionally filter by branch

---

## Install

```bash
curl -fsSL https://eoncode.github.io/runner-bar/install.sh | bash
```

---

## Docs

- [DEVELOPMENT.md](docs/DEVELOPMENT.md) — build and run locally
- [DEPLOYMENT.md](docs/DEPLOYMENT.md) — releases and deployment
- [AGENTS.md](docs/AGENTS.md) — context for AI coding agents
- [docs/TESTING.md](docs/UI_TESTING.md) — UI test runner setup
- [PRIVACY.md](docs/PRIVACY.md) — OAuth scopes, token storage, data handling

---

## Quick deploy

```bash
git pull && git fetch && bash build.sh && pkill RunnerBar; sleep 1 && open dist/RunnerBar.app 2>&1
bash build.sh && bash deploy.sh
curl -fsSL https://eoncode.github.io/runner-bar/install.sh | bash
```

**Test a branch:**
```bash
git fetch && git checkout feature/your-branch && git pull
bash build.sh && pkill RunnerBar; sleep 1 && open dist/RunnerBar.app
```
  
