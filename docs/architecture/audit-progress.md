# Codebase Audit Progress

Tracking file for the principles audit against:
- [Issue #1471](https://github.com/eoncode/runner-bar/issues/1471) + [`project-principles.md`](../architecture/project-principles.md)
- [Issue #1387](https://github.com/eoncode/runner-bar/issues/1387) + [`reach-goal-principles.md`](../principles/reach-goal-principles.md)

Last updated: 2026-06-21 (session 4)

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
| `AppDelegate.swift` | ✅ | **Clean.** `@MainActor` isolated. `AppPreferencesStore.shared` + `ScopeStore.shared` accessed only at construction (injected into `RunnerStore`). One `DispatchQueue.main.async` in `openPanel()` — low risk. No fire-and-forget Tasks. |
| `AppDelegate+PanelSetup.swift` | ✅ | **Finding #51 (new).** Triple `runnerStore = RunnerStore(…)` assignments in `setupSubscriptions()` — first two instances orphaned with live observation Tasks still running (competing poll loops). Log string changes from `setupSubscriptions` → `setupCombineSubscriptions` on copies 2 and 3 confirm paste-artifact origin. `Task { await localRunnerStore.refreshAsync(); await runnerStore.start() }` is actor-bound, not fire-and-forget. KVO `DispatchQueue.main.async` for `resizeAndRepositionPanel` is acceptable. |
| `AppDelegate+Navigation.swift` | ✅ | Finding #15 confirmed — `validatedView(for: .stepLog)` stale guard on `observable.jobs`. TODO comment already present. |
| `AppDelegate+Polling.swift` | 🔲 | |
| `AppDelegate+StatusItem.swift` | 🔲 | |
| `AppDelegate+StoreSetup.swift` | 🔲 | |
| `AppDelegate+OAuthCallback.swift` | 🔲 | |
| `PopoverLifecycleCoordinator.swift` | 🔲 | Medium priority |
| `PanelVisibilityState.swift` | 🔲 | |
| `PanelSheetState.swift` | 🔲 | |
| `NavState.swift` | 🔲 | |

### DesignSystem/
| File | Status | Notes |
|------|--------|-------|
| `DesignTokens.swift` | ⏭️ | Pure UI tokens |
| `PanelViewModifiers.swift` | ✅ | **Clean.** View modifiers only, no async, no GCD, no singletons. |
| `RemovalAlertModifier.swift` | ⏭️ | Small modifier |

### GitHub/
| File | Status | Notes |
|------|--------|-------|
| `GitHubHelpers.swift` | ✅ | Root of Finding #1 — free transport functions `ghAPI`, `ghPost`, `cancelRun`, `fetchActionLogs`, `fetchJobLog` (P7) |
| `GitHubTokenCache.swift` | 🔲 | |
| `OAuthService.swift` | ✅ | **Clean.** `@MainActor` isolated. `Task {}` is actor-bound. |
| `OAuthSecrets.swift` | 🔲 | |

### Preferences/
| File | Status | Notes |
|------|--------|-------|
| `AppPreferencesStore.swift` | 🔲 | |
| `NotificationPreferences.swift` | 🔲 | |

### Runner/
| File | Status | Notes |
|------|--------|-------|
| `RunnerStore.swift` | ✅ | Finding #7 raw string `nextPollInterval()` (P5); protocols `AppPreferencesStoreProtocol`/`ScopeStoreProtocol` defined inline (P6) |
| `RunnerStore+PollBridge.swift` | ✅ | Finding #2 `ScopeStore.shared` bypass (P7); Finding #13 `.scopes` returns disabled scopes — **functional bug** (confirmed) |
| `RunnerLifecycleService.swift` | ✅ | Finding #11 singleton `shared`, no injection seam (P7) |

### Scope/
| File | Status | Notes |
|------|--------|-------|
| `ScopeStore.swift` | ✅ | **Finding #13 confirmed.** `.scopes` = all entries (including disabled); `.activeScopes` = enabled only. `RunnerStore+PollBridge` falls back to `.scopes.first(where:)` — may resolve a disabled scope. |
| `ScopeEntry.swift` | ⏭️ | Small model |

### Services/
| File | Status | Notes |
|------|--------|-------|
| `Keychain.swift` | ✅ | Finding #12 FIXME(P24) atomicity gap |
| `DefaultRunnerLabelsService.swift` | ⏭️ | Small |
| `FailureHookRunner.swift` | 🔲 | |
| `FailureHookRunnerAdapters.swift` | 🔲 | |
| `LoginItem.swift` | ⏭️ | Small |
| `TerminalLauncher.swift` | ⏭️ | Small |

### UseCases/
| File | Status | Notes |
|------|--------|-------|
| `FailureHookRunnerUseCase.swift` | ✅ | **Finding #52 (new).** `fetchFailedJobs` calls `ghAPI(…)` and `fetchJobLog(…)` free functions directly — same P7 DI violation as Findings #1/#50. `Task.detached` in `fireIfNeeded` is **justified** (doc comment explains `Task {}` would serialize through `@MainActor`). **Finding #53 (new).** `JSONDecoder()` allocated per loop iteration inside `fetchFailedJobs` — hoist to top of method. |

### Utilities/
| File | Status | Notes |
|------|--------|-------|
| `WindowGrabber.swift` | ⏭️ | AppKit utility |

### Views/Components/
| File | Status | Notes |
|------|--------|-------|
| `WorkflowContextMenuModifier.swift` | ✅ | Finding #3 three `Task.detached` mutations (P9); Finding #8/#48 `JobContextMenuModifier` confirmed here — `fetchJobLog`/`fetchActionLogs` free function calls (P7) |
| `SystemStatsViewModel.swift` | 🔲 | Medium priority — 12.8 KB |
| `SystemStatsView.swift` | 🔲 | |
| `DonutStatusView.swift` | ⏭️ | Pure rendering |
| `SparklineView.swift` | ⏭️ | Pure rendering |
| `RingBuffer.swift` | ⏭️ | Data structure |

### Views/Main/
| File | Status | Notes |
|------|--------|-------|
| `InlineJobRowsView.swift` | ✅ | Finding #20 confirmed — `jobStatus(for:)` duplicates `ActionRowView.rowStatus` conclusion→`RBStatus` mapping (TODO/NOSONAR comment in file). P5 clean — uses typed `JobConclusion`/`JobStatus` throughout. |
| `ActionRowView.swift` | ✅ | **Clean.** `rowStatus` uses typed enums (P5 compliant). No GCD, no singleton access, no fire-and-forget tasks. |
| `PanelContainerView.swift` | 🔲 | |
| `PanelMainView.swift` | ✅ | Finding #19 — `localRunnerStore: LocalRunnerStore = .shared` defaulted property exposes singleton (P7) |
| `RunnerRowViews.swift` | 🔲 | |
| `WorkflowActionGroup+Progress.swift` | ✅ | Finding #25 — `progressFraction` done-semantics inconsistency |
| `PanelHeaderView.swift` | ⏭️ | Small |
| `PanelMainView+Subviews.swift` | ⏭️ | Small |

### Views/Runner/
| File | Status | Notes |
|------|--------|-------|
| `RunnerViewModel.swift` | ⏭️ | Small |

### Views/Settings/
| File | Status | Notes |
|------|--------|-------|
| `ScopeEditSheet.swift` | 🔲 | **Highest priority unread** — 26.5 KB |
| `AddRunnerSheet.swift` | ✅ | Finding #23 — `ScopeType` enum redefined (P6 DRY) |
| `LocalRunnersView.swift` | ✅ | Finding #22 — `localRunnerDotColor(for:)` duplicated in `RunnerDetailSheet` |
| `RunnerDetailSheet.swift` | ✅ | Finding #22 call site |
| `AddRunnerSheet+FormFields.swift` | ✅ | Finding #23 call site |
| `SettingsView.swift` | 🔲 | |
| `ScopesView.swift` | ✅ | Clean |
| `SettingsView+Sections.swift` | ✅ | Clean |
| `FailureHookCommandSheet.swift` | ✅ | Clean |
| `AddScopeSheet.swift` | ✅ | Finding #23 — `ScopeType` private redefinition |
| `AddRunnerSheet+TokenSection.swift` | ⏭️ | Small |
| `AddRunnerSheet+Validation.swift` | ⏭️ | Small |

### Views/Sheets/
| File | Status | Notes |
|------|--------|-------|
| `BranchSelectorSheet.swift` | ✅ | Finding #9 `ghAPI` free function call (P7); Finding #24 structural duplication with `RepoSelectorSheet` |
| `RepoSelectorSheet.swift` | ✅ | Finding #24 call site |

### Views/StepLog/
| File | Status | Notes |
|------|--------|-------|
| `StepLogView.swift` | ✅ | Finding #4 `Task.detached` + `ScopeStore.shared` (P9+P7); Finding #5 GCD round-trip (P2); Finding #6 raw string comparisons (P5) |
| `LogCopyButton.swift` | ✅ | Finding #5 call site |

### Root
| File | Status | Notes |
|------|--------|-------|
| `main.swift` | 🔲 | Entry point |
| `Exports.swift` | ⏭️ | Re-exports only |

---

## RunnerBarCore (core target)

### GitHub/
| File | Status | Notes |
|------|--------|-------|
| `GitHubTransportShim.swift` | ✅ | Root of Finding #1 — free functions defined here |
| `GitHubURLSessionTransport.swift` | ✅ | **Clean.** One intentional `DispatchQueue.sync {}` documented. No new findings. |
| `GitHubRateLimitHandler.swift` | 🔲 | |
| `GitHubResponseDecoder.swift` | 🔲 | |
| `GitHubRequestBuilder.swift` | 🔲 | |
| `GitHubConstants.swift` | ⏭️ | Constants |

### Runner/
| File | Status | Notes |
|------|--------|-------|
| `PollResultBuilder.swift` | ✅ | **Clean.** Pure static, all side-effects injected. Typed enums throughout. Finding #16 cosmetic duplication. |
| `WorkflowActionGroupFetch.swift` | ✅ | **Finding #50.** `fetchActionGroups`/`fetchJobsForRun`/`fetchJobsForGroup` call `ghAPI(…)` free function directly (P7) |
| `RunnerStatusEnricher.swift` | ✅ | Finding #2b singleton as default param; Finding #8 `JSONDecoder()` per pagination loop |
| `RunnerConfigStore.swift` | ✅ | Finding #6 BOM stripping duplicated (P6 DRY) |
| `SaveRunnerEditsUseCase.swift` | ✅ | Finding #7 `LabelsPrerequisiteError` internal, typed error lost at module boundary |
| `ActiveJob.swift` | ✅ | Finding #25 call site — `progressFraction` done-semantics |
| `JobStatus.swift` | 🔲 | Check enum completeness (relates to #6/#7) |
| `RunnerModel.swift` | ✅ | Clean |
| `RunnerMetrics.swift` | ✅ | Finding #13b — `pgrep`→`ps` pipeline duplicated (P6 DRY) |
| `RunnerModelParser.swift` | ✅ | Finding #6 BOM stripping duplicated (P6 DRY) |
| `LocalRunnerIndex.swift` | ✅ | Clean |
| `RunnerEditDraft.swift` | ⏭️ | Small model |
| `WorkflowActionGroup.swift` | ✅ | Finding #10 — identity-only `==` misses field mutations |
| `RunnerConfigStoreProtocol.swift` | ⏭️ | Protocol definition |
| `RunnerLabelsServiceProtocol.swift` | ⏭️ | Protocol definition |
| `RunnerStatusEnricherProtocol.swift` | ⏭️ | Protocol definition |
| `RunnerProxyStoreProtocol.swift` | ⏭️ | Protocol definition |
| `RunnerProxyStoreError.swift` | ⏭️ | Small |
| `RunnerProxyConfig.swift` | ⏭️ | Small model |
| `RunnerStatus.swift` | ⏭️ | Small model |
| `AggregateStatus.swift` | ⏭️ | Small model |
| `CommitResult.swift` | ⏭️ | Small model |
| `Runner.swift` | 🔲 | |
| `RunnerConfig.swift` | ⏭️ | Small model |

### Scope/
| File | Status | Notes |
|------|--------|-------|
| `ScopePreferencesStore.swift` | ✅ | Finding #11b — `UserDefaults.standard` hardcoded, not injectable (P7) |
| `ScopeEntry.swift` | ⏭️ | Small model |
| `GitHubScope.swift` | ⏭️ | Small model |
| `FailureHookRunnerDependencies.swift` | 🔲 | |

### Services/
| File | Status | Notes |
|------|--------|-------|
| `ProcessRunner.swift` | ✅ | **Clean (by design).** Intentional `DispatchQueue.sync {}` and `Task.detached` — both documented. |
| `LogFetcher.swift` | 🔲 | Relates to Finding #4/#52 log fetch chain |

### Utilities/
| File | Status | Notes |
|------|--------|-------|
| `AnyJSON.swift` | ⏭️ | JSON utility |
| `FormatElapsed.swift` | ⏭️ | Formatting |
| `GitHubURLHelpers.swift` | ⏭️ | URL helpers |
| `ISO8601DateParser.swift` | ⏭️ | Parser |
| `Logger.swift` | ⏭️ | Logging wrapper |
| `SystemStats.swift` | ⏭️ | Small |

---

## All Confirmed Findings (Ranked by Priority)

| # | File | Principle | Tier | Notes |
|---|------|-----------|------|-------|
| 1 | `GitHubHelpers.swift` / `GitHubTransportShim.swift` — free transport functions | P7 DI | 🔴 1 | Root cause of #8, #9, #50, #52 |
| 51 | `AppDelegate+PanelSetup.swift` — triple `RunnerStore` init, orphaned Tasks | P9 | 🔴 1 | **New** — competing poll loops |
| 2 | `RunnerStore+PollBridge.swift` — `ScopeStore.shared` bypass | P7 DI | 🔴 1 | Ignores injected `scopeStore` |
| 13 | `RunnerStore+PollBridge.swift` — `.scopes` returns disabled scopes | P5 bug | 🔴 1 | **Upgraded** — functional bug |
| 3 | `WorkflowContextMenuModifier.swift` — 3× `Task.detached` mutations | P9 + P7 | 🔴 1 | Silent failure swallowing |
| 50 | `WorkflowActionGroupFetch.swift` — `ghAPI` on hot poll path | P7 DI | 🔴 1 | Every poll cycle |
| 4 | `StepLogView.loadLog` — `Task.detached` + `ScopeStore.shared` | P9 + P7 | 🔴 1 | View dealloc risk |
| 52 | `FailureHookRunnerUseCase.fetchFailedJobs` — `ghAPI`/`fetchJobLog` direct | P7 DI | 🟠 2 | **New** — blocked by #1 |
| 5 | `StepLogView` → `LogCopyButton` — GCD round-trip | P2 GCD | 🟠 2 | Trivial fix |
| 6 | `StepLogView` — raw string status comparisons | P5 typed | 🟠 2 | Silent forward-compat risk |
| 7 | `RunnerStore.nextPollInterval` — raw string `JobStatus` | P5 typed | 🟠 2 | Disables fast-poll silently |
| 8 | `JobContextMenuModifier` (in `WorkflowContextMenuModifier.swift`) — free fn | P7 DI | 🟠 2 | Blocked by #1 |
| 9 | `BranchSelectorSheet.fetchBranchNames` — `ghAPI` free fn | P7 DI | 🟠 2 | Blocked by #1 |
| 53 | `FailureHookRunnerUseCase.fetchFailedJobs` — `JSONDecoder()` per loop | P6 | 🟡 3 | **New** — hoist to method top |
| 20 | `InlineJobRowsView.jobStatus` — duplicates `ActionRowView.rowStatus` | P6 DRY | 🟡 3 | TODO already in file |
| 10 | `WorkflowActionGroup` — identity-only `==` misses field mutations | P5 | 🟡 3 | |
| 12 | `Keychain.swift` — FIXME(P24) atomicity gap | P24 | 🟡 3 | Tracked FIXME |
| 11 | `RunnerLifecycleService` — singleton, no injection seam | P7 DI | 🟢 4 | Low urgency |

---

## Next Files to Read (Priority Order)

1. `RunnerBar/Views/Settings/ScopeEditSheet.swift` — **26.5 KB, largest unread file**
2. `RunnerBarCore/Services/LogFetcher.swift` — log fetch chain (relates to #4, #52)
3. `RunnerBarCore/Runner/JobStatus.swift` — enum completeness (relates to #6, #7)
4. `RunnerBar/App/AppDelegate+Polling.swift`
5. `RunnerBar/Views/Components/SystemStatsViewModel.swift` — 12.8 KB
6. `RunnerBar/Views/Settings/SettingsView.swift` — 10.6 KB
7. `RunnerBarCore/Runner/Runner.swift`
8. `RunnerBarCore/GitHub/GitHubRateLimitHandler.swift`
