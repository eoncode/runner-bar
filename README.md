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
- Live run status across all your repos and orgs — expand any run into a full **Workflow → Jobs → Steps** tree with elapsed time and live progress
- Drill into jobs and steps; copy logs at the workflow, job, or step level
- Re-run all, re-run failed jobs, or cancel directly from the panel or right-click context menu
- Right-click a run to open the workflow or commit on GitHub

**🏃 Local runner manager**
- Provision new runners in one click — the app handles the token, the install script, and the registration with GitHub
- Add pre-existing runners already on your Mac
- Start, stop, and deregister runners directly from the UI — no Terminal or github.com required
- Active runners show live **CPU & memory** badges while a job is in progress

**🪝 Failure hooks**
- When a run fails, automatically fire a custom shell command in Terminal
- Tokens substituted before the command runs: `$SCOPE`, `$LOCAL_PATH`, `$BRANCH`, `$RUN_ID`, `$COMMIT_SHA`, `$WORKFLOW_NAME`, `$FAILURE_LOG`, `$RUN_LINK`, `$COMMIT_LINK`, `$BRANCH_LINK`, `$REPO_LINK`
- Works with any AI CLI — Claude Code, Gemini, Aider, Codex, or anything that accepts terminal input
- Configurable per repo or org; optionally filter by branch
- **Test** button fires the command immediately from the settings sheet

---

## Install

```bash
curl -fsSL https://eoncode.github.io/runner-bar/install.sh | bash
```

---

## Docs

- [Development](docs/guides/development.md) — build and run locally
- [Deployment](docs/guides/deployment.md) — releases and deployment
- [UI Testing](docs/guides/ui-testing.md) — UI test runner setup
- [AI Review](docs/guides/ai-review.md) — AI reviewer configuration
- [Agents](docs/architecture/agents.md) — context for AI coding agents
- [Privacy](docs/legal/privacy.md) — OAuth scopes, token storage, data handling

---

## Concurrency

All UI state lives on `@MainActor`. Background domain work is isolated in dedicated actors — there is no single shared background queue. The boundary-crossing pattern is explicit at every call site:

```swift
let scopes = await MainActor.run { scopeStore.activeScopes }
```

Timers use `Task` + `Task.sleep(for:)` (never `DispatchQueue`), guarded by a generation counter to prevent stale-task races. Related values crossing an actor boundary are always fetched atomically via a `snapshot()` method or `async let` binding — never with two sequential `await` calls. The entire model is compiler-enforced: no `@unchecked Sendable` in production types.

→ [`docs/architecture/concurrency-overview.md`](docs/architecture/concurrency-overview.md)

---

## Module Separation

The codebase is split into two SPM targets:

- **`RunnerBarCore`** — pure Swift library; no AppKit, no app bundle, no entitlements. All networking, use-cases, actors, and Codable models live here. Testable with `swift test` in CI — no simulator, no signing.
- **`RunnerBar`** — the macOS app target. Imports Core and adds UI, `@Observable` ViewModels, AppKit integrations (`NSWorkspace`, `ServiceManagement`), and Keychain access.

The compiler enforces the boundary: importing `AppKit` inside Core is a build error. This keeps business logic framework-agnostic and gives SonarCloud and Periphery a clean, high-signal surface to analyse.

→ [`docs/architecture/library-rationale.md`](docs/architecture/library-rationale.md)

---

## Model Philosophy

Models are immutable `Sendable` value types (`struct`) by default. `@Observable` classes are used only for ViewModels that need SwiftUI change propagation. Actors own all mutable state that crosses async boundaries. Use-cases (e.g. `WorkflowActionsUseCase`, `FailureHookRunnerUseCase`) are non-isolated `Sendable` structs with no stored mutable state — they run on the cooperative thread pool and depend only on injected protocols, making them trivially unit-testable. Persisted configuration is typed `Codable` — no stringly-typed `UserDefaults` keys in Core.

→ [`docs/architecture/data-model.md`](docs/architecture/data-model.md) · [`docs/principles/project-principles.md`](docs/principles/project-principles.md)

---

**Test a branch:**
```bash
git fetch && git checkout feature/your-branch && git pull
bash build.sh && pkill RunnerBar; sleep 1 && open dist/RunnerBar.app
```
  
