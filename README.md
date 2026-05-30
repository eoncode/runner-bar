# RunnerBar 

**Platform & Stack**

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple&logoColor=white)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![Liquid Glass](https://img.shields.io/badge/UI-Liquid%20Glass-0A84FF?style=flat-square&logo=apple&logoColor=white)

**CI Checks**

![UI Tests](https://github.com/eoncode/runner-bar/actions/workflows/ui-tests.yml/badge.svg)
![Unit Tests](https://github.com/eoncode/runner-bar/actions/workflows/swift-test.yml/badge.svg)
![SwiftLint](https://github.com/eoncode/runner-bar/actions/workflows/swiftlint.yml/badge.svg)
![Periphery](https://github.com/eoncode/runner-bar/actions/workflows/periphery.yml/badge.svg)
[![CodeQL](https://github.com/eoncode/runner-bar/actions/workflows/codeql.yml/badge.svg)](https://github.com/eoncode/runner-bar/actions/workflows/codeql.yml)

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

## GitHub OAuth Permissions

RunnerBar uses a classic OAuth token. The following scopes are requested and are all load-bearing:

| Scope | Why it's needed |
|---|---|
| `repo` | Read workflow runs, jobs, steps, and logs across private repositories |
| `read:org` | Discover which organisations the authenticated user belongs to |
| `admin:org` | Call `GET /orgs/{org}/actions/runners` to fetch org-level runner labels (e.g. `arm64`, `macOS`). Required for classic OAuth tokens — `manage_runners:org` alone is only sufficient for fine-grained PATs |
| `manage_runners:org` | Forward-compatibility: GitHub is migrating runner APIs to require this scope for fine-grained tokens; included so the token stays valid as GitHub enforces newer auth requirements |
| `workflow` | Trigger re-run, re-run failed, and cancel actions on workflow runs |

> **Note:** `admin:org` is not a broad privilege grab. It is the documented requirement for classic OAuth tokens when calling org-runner endpoints. See [GitHub docs](https://docs.github.com/en/rest/actions/self-hosted-runners).

---

## Docs

- [DEVELOPMENT.md](DEVELOPMENT.md) — build and run locally
- [DEPLOYMENT.md](DEPLOYMENT.md) — releases and deployment
- [AGENTS.md](AGENTS.md) — context for AI coding agents
- [docs/TESTING.md](docs/TESTING.md) — UI test runner setup

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
  
