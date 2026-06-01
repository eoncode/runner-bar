# RunnerBar 

**Platform & Stack**

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-000000?logo=apple&logoColor=white)
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

RunnerBar uses a classic GitHub OAuth token. Every scope below is required by a specific feature — nothing is requested speculatively.


| Scope | What it enables in RunnerBar |
| :-- | :-- |
| `repo` | Shows live workflow runs, jobs, steps, and logs for your **private** repositories. Without this, only public repo runs are visible. |
| `read:org` | Discovers which organisations your account belongs to, so RunnerBar can list workflows across all your org repos — not just personal ones. |
| `admin:org` | Required to **add and remove self-hosted runners** at the org level. RunnerBar calls GitHub's runner registration-token and remove-token endpoints, and can deregister a runner directly via the API when the local `config.sh` script is unavailable. This is the only scope that covers these write operations on classic tokens. |
| `manage_runners:org` | Included for forward-compatibility. GitHub is migrating runner management APIs to require this scope for fine-grained tokens. Requesting it now ensures the token stays valid as GitHub enforces the newer auth model. |
| `workflow` | Powers the **Re-run**, **Re-run failed**, and **Cancel** buttons in the popover. These actions require an explicit write scope — read-only tokens will silently fail. |

### Why `admin:org` is not a broad privilege

`admin:org` sounds alarming, but RunnerBar uses it for a narrow set of runner lifecycle calls only: fetching a short-lived registration token, fetching a removal token, and deleting a runner by ID. No org membership, billing, settings, or secrets are accessed. GitHub does not offer a narrower scope for these operations on classic OAuth tokens — `manage_runners:org` only covers them for fine-grained PATs.

> **Why not a fine-grained PAT?** Fine-grained tokens do not yet support all Actions and runner management endpoints RunnerBar depends on. Classic OAuth is currently the only option that covers the full feature set.

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
  
