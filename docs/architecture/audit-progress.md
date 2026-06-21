# Codebase Audit Progress

Tracking file for the principles audit against:
- [Issue #1471](https://github.com/eoncode/runner-bar/issues/1471) + [`project-principles.md`](../architecture/project-principles.md)
- [Issue #1387](https://github.com/eoncode/runner-bar/issues/1387) + [`reach-goal-principles.md`](../principles/reach-goal-principles.md)

Last updated: 2026-06-21 (session 3)

---

## Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | File read and fully analysed |
| 🔲 | File not yet read |
| ⏭️ | Skipped — low signal (pure UI layout, design tokens, small model) |

---

## RunnerBar (app target)

### App/
| File | Status | Notes |
|------|--------|-------|
| `AppDelegate.swift` (23 KB) | ✅ | **Clean.** `@MainActor` isolated correctly. `AppPreferencesStore.shared` + `ScopeStore.shared` accessed only at construction (injected into `RunnerStore` at `setupCombineSubscriptions`). `DispatchQueue.main.async` used once in `openPanel()` for a one-shot UI restore — low risk. No fire-and-forget Tasks. No new findings. |
| `AppDelegate+PanelSetup.swift` (14 KB) | 🔲 | High priority — DI wiring for `RunnerStore` init |
| `AppDelegate+Navigation.swift` (5.4 KB) | 🔲 | |
| `AppDelegate+Polling.swift` (1.5 KB) | 🔲 | |
| `AppDelegate+StatusItem.swift` (3.2 KB) | 🔲 | |
| `AppDelegate+StoreSetup.swift` (1.5 KB) | 🔲 | |
| `AppDelegate+OAuthCallback.swift` (816 B) | 🔲 | |
| `PopoverLifecycleCoordinator.swift` (12.8 KB) | 🔲 | Medium priority |
| `PanelVisibilityState.swift` (6.8 KB) | 🔲 | |
| `PanelSheetState.swift` (1.6 KB) | 🔲 | |
| `NavState.swift` (1.2 KB) | 🔲 | |

### DesignSystem/
| File | Status | Notes |
|------|--------|-------|
| `DesignTokens.swift` (8 KB) | ⏭️ | Pure UI tokens — no principle violations expected |
| `PanelViewModifiers.swift` (14 KB) | 🔲 | Check for GCD/Task misuse in modifiers |
| `RemovalAlertModifier.swift` (1.9 KB) | ⏭️ | Small modifier |

### GitHub/
| File | Status | Notes |
|------|--------|-------|
| `GitHubHelpers.swift` (9.1 KB) | ✅ | Contains free transport functions `ghAPI`, `ghPost`, `cancelRun`, `fetchActionLogs`, `fetchJobLog` — root of Finding #1 (P7) |
| `GitHubTokenCache.swift` (4.2 KB) | 🔲 | |
| `OAuthService.swift` (15.2 KB) | ✅ | **Clean.** `@MainActor` isolated. Uses own `URLSession.shared.data(for:)` directly (correct — OAuth token exchange is a one-off, not a polling path). `Task { await exchangeCode(code) }` in `handleCallback` is actor-bound (inherits `@MainActor`), not fire-and-forget. No new findings. |
| `OAuthSecrets.swift` (2.4 KB) | 🔲 | |

### Preferences/
| File | Status | Notes |
|------|--------|-------|
| `AppPreferencesStore.swift` (4.4 KB) | 🔲 | Relates to `AppPreferencesStoreProtocol` used in RunnerStore |
| `NotificationPreferences.swift` (2 KB) | 🔲 | |

### Runner/
| File | Status | Notes |
|------|--------|-------|
| `RunnerStore.swift` | ✅ | Finding #7 raw string in `nextPollInterval()` (P5); protocols `AppPreferencesStoreProtocol`/`ScopeStoreProtocol` defined here (P6) |
| `RunnerStore+PollBridge.swift` | ✅ | Finding #2 `ScopeStore.shared` bypass (P7); Finding #13 `.scopes` vs `.activeScopes` — **confirmed real** (see ScopeStore notes below) |
| `RunnerLifecycleService.swift` | ✅ | Finding #11 singleton `shared` with no injection seam (P7) |

### Scope/
| File | Status | Notes |
|------|--------|-------|
| `ScopeStore.swift` | ✅ | **Finding #13 confirmed.** `.scopes` returns ALL entries (including disabled); `.activeScopes` returns only enabled ones. `RunnerStore+PollBridge` calls `ScopeStore.shared.scopes.first(where: { $0.contains("/") })` — it may return a **disabled** scope as fallback, which is semantically wrong. Fix: replace with `.activeScopes`. |
| `ScopeEntry.swift` | ⏭️ | Small model |

### Services/
| File | Status | Notes |
|------|--------|-------|
| `Keychain.swift` (7.4 KB) | ✅ | Finding #12 FIXME(P24) atomicity gap between SecItemUpdate/Add |
| `DefaultRunnerLabelsService.swift` (845 B) | ⏭️ | Small |
| `FailureHookRunner.swift` (1.9 KB) | 🔲 | |
| `FailureHookRunnerAdapters.swift` (1.7 KB) | 🔲 | |
| `LoginItem.swift` (1.2 KB) | ⏭️ | Small |
| `TerminalLauncher.swift` (1 KB) | ⏭️ | Small |

### UseCases/
| File | Status | Notes |
|------|--------|-------|
| `FailureHookRunnerUseCase.swift` (16.3 KB) | 🔲 | Medium priority — largest use case, check P7/P9 |

### Utilities/
| File | Status | Notes |
|------|--------|-------|
| `WindowGrabber.swift` (2.2 KB) | ⏭️ | AppKit window utility |

### Views/Components/
| File | Status | Notes |
|------|--------|-------|
| `WorkflowContextMenuModifier.swift` (7.6 KB) | ✅ | Finding #3 three `Task.detached` fire-and-forget mutations (P9); Finding #48 free function calls (P7) |
| `SystemStatsViewModel.swift` (12.8 KB) | 🔲 | Medium priority — ViewModel with possible GCD/Task issues |
| `SystemStatsView.swift` (9.4 KB) | 🔲 | |
| `DonutStatusView.swift` (5.1 KB) | ⏭️ | Pure rendering view |
| `SparklineView.swift` (3.6 KB) | ⏭️ | Pure rendering view |
| `RingBuffer.swift` (1.2 KB) | ⏭️ | Data structure |

### Views/Main/
| File | Status | Notes |
|------|--------|-------|
| `InlineJobRowsView.swift` (14.6 KB) | 🔲 | Medium priority — contains `JobContextMenuModifier` usage |
| `ActionRowView.swift` (10.5 KB) | 🔲 | |
| `PanelContainerView.swift` (12.9 KB) | 🔲 | |
| `PanelMainView.swift` (9.1 KB) | 🔲 | |
| `RunnerRowViews.swift` (7.1 KB) | 🔲 | |
| `WorkflowActionGroup+Progress.swift` (5.3 KB) | 🔲 | |
| `PanelHeaderView.swift` (2.5 KB) | ⏭️ | Small view |
| `PanelMainView+Subviews.swift` (580 B) | ⏭️ | Small |

### Views/Runner/
| File | Status | Notes |
|------|--------|-------|
| `RunnerViewModel.swift` (2 KB) | ⏭️ | Small |

### Views/Settings/
| File | Status | Notes |
|------|--------|-------|
| `ScopeEditSheet.swift` (26.5 KB) | 🔲 | **Largest settings file** — high priority |
| `AddRunnerSheet.swift` (18.6 KB) | 🔲 | Medium priority |
| `LocalRunnersView.swift` (17.2 KB) | 🔲 | Medium priority |
| `RunnerDetailSheet.swift` (15.7 KB) | 🔲 | Medium priority |
| `AddRunnerSheet+FormFields.swift` (16.2 KB) | 🔲 | |
| `SettingsView.swift` (10.6 KB) | 🔲 | |
| `ScopesView.swift` (7.8 KB) | 🔲 | |
| `SettingsView+Sections.swift` (9.7 KB) | 🔲 | |
| `FailureHookCommandSheet.swift` (10 KB) | 🔲 | |
| `AddScopeSheet.swift` (13.1 KB) | 🔲 | |
| `AddRunnerSheet+TokenSection.swift` (3.5 KB) | 🔲 | |
| `AddRunnerSheet+Validation.swift` (2.3 KB) | ⏭️ | Small |

### Views/Sheets/
| File | Status | Notes |
|------|--------|-------|
| `BranchSelectorSheet.swift` (10.6 KB) | ✅ | Finding #9 `ghAPI` free function call, no transport DI (P7) |
| `RepoSelectorSheet.swift` (6.8 KB) | 🔲 | Check for same free function pattern |

### Views/StepLog/
| File | Status | Notes |
|------|--------|-------|
| `StepLogView.swift` (15.7 KB) | ✅ | Finding #4 `Task.detached` + `ScopeStore.shared` (P9+P7); Finding #5 `DispatchQueue.global` round-trip (P2); Finding #6 raw string status comparisons (P5) |
| `LogCopyButton.swift` (3.8 KB) | ✅ | Finding #5 call site — GCD hop from StepLogView (P2) |

### Root
| File | Status | Notes |
|------|--------|-------|
| `main.swift` (756 B) | 🔲 | Entry point |
| `Exports.swift` (550 B) | ⏭️ | Re-exports only |

---

## RunnerBarCore (core target)

### GitHub/
| File | Status | Notes |
|------|--------|-------|
| `GitHubTransportShim.swift` (9.4 KB) | ✅ | Root of Finding #1 — free functions `ghAPI`/`ghPost`/etc. defined here |
| `GitHubURLSessionTransport.swift` (29.5 KB) | ✅ | **Clean.** Well-structured. `urlSessionExecute` is private `@concurrent`, all public wrappers delegate cleanly. One intentional `DispatchQueue.sync {}` in `handleTermination` (P2 known/documented, last GCD sync in production path). Rate-limit actor properly used. No new findings. |
| `GitHubRateLimitHandler.swift` (14.2 KB) | 🔲 | |
| `GitHubResponseDecoder.swift` (5.5 KB) | 🔲 | |
| `GitHubRequestBuilder.swift` (2.3 KB) | 🔲 | |
| `GitHubConstants.swift` (2.8 KB) | ⏭️ | Constants |

### Runner/
| File | Status | Notes |
|------|--------|-------|
| `PollResultBuilder.swift` (20.5 KB) | ✅ | **Clean.** Pure static struct. All side-effects injected as closures (`fetchJobs`, `backfill`, `fetchGroups`, `fireFailureHook`, `enrichJobs`). No free function calls, no singleton access, no GCD. Uses typed `JobStatus.inProgress`/`.queued`/`.completed` enum values throughout — consistent with P5. No new findings. |
| `WorkflowActionGroupFetch.swift` (15.4 KB) | ✅ | **Finding #50 (new).** `fetchActionGroups`, `fetchJobsForRun`, `fetchJobsForGroup` are free functions that call `ghAPI(…)` directly — same P7 transport DI violation as Finding #1. Also: `fetchJobsForGroup` uses raw `JobStatus.inProgress` enum correctly (P5 clean). `withTaskGroup` usage is structured, no fire-and-forget. Only violation: direct `ghAPI` free function calls with no injection seam. |
| `RunnerStatusEnricher.swift` (15.7 KB) | 🔲 | Medium priority |
| `RunnerConfigStore.swift` (14.4 KB) | 🔲 | Medium priority |
| `SaveRunnerEditsUseCase.swift` (11.8 KB) | 🔲 | Medium priority |
| `ActiveJob.swift` (15.4 KB) | 🔲 | Medium priority |
| `JobStatus.swift` (9.7 KB) | 🔲 | Check `JobStatus`/`JobConclusion` enum completeness (relates to Findings #6/#7) |
| `RunnerModel.swift` (13.1 KB) | 🔲 | |
| `RunnerMetrics.swift` (6.5 KB) | 🔲 | |
| `RunnerModelParser.swift` (4.5 KB) | 🔲 | |
| `LocalRunnerIndex.swift` (5 KB) | 🔲 | |
| `RunnerEditDraft.swift` (5.2 KB) | 🔲 | |
| `WorkflowActionGroup.swift` (18.1 KB) | 🔲 | |
| `RunnerConfigStoreProtocol.swift` (1 KB) | ⏭️ | Protocol definition |
| `RunnerLabelsServiceProtocol.swift` (1.2 KB) | ⏭️ | Protocol definition |
| `RunnerStatusEnricherProtocol.swift` (1.5 KB) | ⏭️ | Protocol definition |
| `RunnerProxyStoreProtocol.swift` (811 B) | ⏭️ | Protocol definition |
| `RunnerProxyStoreError.swift` (675 B) | ⏭️ | Small |
| `RunnerProxyConfig.swift` (1.6 KB) | ⏭️ | Small model |
| `RunnerStatus.swift` (2.6 KB) | ⏭️ | Small model |
| `AggregateStatus.swift` (1.8 KB) | ⏭️ | Small model |
| `CommitResult.swift` (417 B) | ⏭️ | Small model |
| `Runner.swift` (5 KB) | 🔲 | |
| `RunnerConfig.swift` (3.3 KB) | ⏭️ | Small model |

### Scope/
| File | Status | Notes |
|------|--------|-------|
| `ScopePreferencesStore.swift` (8.1 KB) | 🔲 | |
| `ScopeEntry.swift` (2.4 KB) | ⏭️ | Small model |
| `GitHubScope.swift` (1.2 KB) | ⏭️ | Small model |
| `FailureHookRunnerDependencies.swift` (1.5 KB) | 🔲 | |

### Services/
| File | Status | Notes |
|------|--------|-------|
| `ProcessRunner.swift` (21.4 KB) | ✅ | **Clean (by design).** One intentional `DispatchQueue.sync {}` in `handleTermination` — the last GCD sync in the production path, deliberately retained as the happens-before edge for stdout drain. Doc comment explicitly blocks AI suggestions to remove it. `Task.detached` used for the timeout guard only, with a documented and bounded lifetime (cancelled by `terminationHandler` on process exit). No new findings — existing P2 item is tracked and justified. |
| `LogFetcher.swift` (5.3 KB) | 🔲 | Relates to Finding #4/#9 log fetch chain |

### Utilities/
| File | Status | Notes |
|------|--------|-------|
| `AnyJSON.swift` (3.8 KB) | ⏭️ | JSON utility |
| `FormatElapsed.swift` (1.1 KB) | ⏭️ | Formatting utility |
| `GitHubURLHelpers.swift` (1.3 KB) | ⏭️ | URL helpers |
| `ISO8601DateParser.swift` (1.6 KB) | ⏭️ | Parser |
| `Logger.swift` (1.2 KB) | ⏭️ | Logging wrapper |
| `SystemStats.swift` (1.7 KB) | ⏭️ | Small |

---

## Findings Summary (all confirmed findings to date)

| # | File | Principle | Tier | Status |
|---|------|-----------|------|--------|
| 1 | `GitHubHelpers.swift` / `GitHubTransportShim.swift` | P7 — DI | 🔴 1 | Open |
| 2 | `RunnerStore+PollBridge.swift` — `ScopeStore.shared` bypass | P7 — DI | 🔴 1 | Open |
| 3 | `WorkflowContextMenuModifier.swift` — 3× `Task.detached` mutations | P9 + P7 | 🔴 1 | Open |
| 4 | `StepLogView.swift` — `Task.detached` + `ScopeStore.shared` | P9 + P7 | 🔴 1 | Open |
| 5 | `StepLogView.swift` → `LogCopyButton.swift` — GCD round-trip | P2 — GCD | 🟠 2 | Open |
| 6 | `StepLogView.swift` — raw string status comparisons | P5 — typed | 🟠 2 | Open |
| 7 | `RunnerStore.swift` — raw string in `nextPollInterval()` | P5 — typed | 🟠 2 | Open |
| 8 | `JobContextMenuModifier` (location TBD) | P7 — DI | 🟠 2 | Unconfirmed location |
| 9 | `BranchSelectorSheet.swift` — `ghAPI` free function | P7 — DI | 🟠 2 | Open |
| 10 | `RunnerStore.swift` — protocols defined inline | P6 — SRP | 🟢 4 | Open |
| 11 | `RunnerLifecycleService.swift` — singleton, no injection seam | P7 — DI | 🟢 4 | Open |
| 12 | `Keychain.swift` — FIXME(P24) atomicity gap | P24 | 🟢 4 | Tracked |
| 13 | `RunnerStore+PollBridge.swift` — `.scopes` vs `.activeScopes` | P5 — correctness | 🔴 1* | **UPGRADED** — `.scopes` returns disabled scopes; semantically wrong fallback |
| 50 | `WorkflowActionGroupFetch.swift` — `ghAPI` free function calls | P7 — DI | 🟠 2 | Open |

*Finding #13 upgraded to 🔴 after confirming `ScopeStore.scopes` includes **disabled** scopes. The fallback in `StepLogView.loadLog` may resolve a disabled scope — a functional bug, not just a style violation.

---

## Next Files to Read (Priority Order)

1. `RunnerBar/App/AppDelegate+PanelSetup.swift` (14 KB) — DI wiring for RunnerStore
2. `RunnerBar/Views/Settings/ScopeEditSheet.swift` (26.5 KB) — largest settings file
3. `RunnerBar/Views/Main/InlineJobRowsView.swift` (14.6 KB) — locate `JobContextMenuModifier` (Finding #8)
4. `RunnerBar/UseCases/FailureHookRunnerUseCase.swift` (16.3 KB)
5. `RunnerBarCore/Runner/RunnerStatusEnricher.swift` (15.7 KB)
6. `RunnerBarCore/Runner/ActiveJob.swift` (15.4 KB)
7. `RunnerBarCore/Services/LogFetcher.swift` (5.3 KB)
8. `RunnerBarCore/Runner/JobStatus.swift` (9.7 KB)
9. `RunnerBar/Views/Settings/AddRunnerSheet.swift` (18.6 KB)
10. `RunnerBar/Views/Settings/LocalRunnersView.swift` (17.2 KB)
