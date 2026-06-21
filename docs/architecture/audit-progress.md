# Codebase Audit Progress

Tracking file for the principles audit against:
- [Issue #1471](https://github.com/eoncode/runner-bar/issues/1471) + [`project-principles.md`](../architecture/project-principles.md)
- [Issue #1387](https://github.com/eoncode/runner-bar/issues/1387) + [`reach-goal-principles.md`](../principles/reach-goal-principles.md)

Last updated: 2026-06-21 (session 6)

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
| `AppDelegate.swift` | ✅ | **Clean.** `@MainActor` isolated. Singletons accessed only at construction (injected into `RunnerStore`). |
| `AppDelegate+PanelSetup.swift` | ✅ | **Finding #51.** Triple `RunnerStore` init — first two orphaned with live Tasks (competing poll loops). |
| `AppDelegate+Navigation.swift` | ✅ | Finding #15 confirmed — stale guard on `observable.jobs`. TODO present. |
| `AppDelegate+Polling.swift` | ✅ | **Clean.** `setupSignOutSubscription()` creates one actor-bound `Task { [weak self] }` on `AppDelegate` lifetime. `for await` stream loop is structured. `OAuthService.shared` is the only singleton — it is the natural app-lifetime service (documented why). No fire-and-forget, no GCD. |
| `AppDelegate+StatusItem.swift` | 🔲 | |
| `AppDelegate+StoreSetup.swift` | 🔲 | |
| `AppDelegate+OAuthCallback.swift` | 🔲 | |
| `PopoverLifecycleCoordinator.swift` | ✅ | **Clean.** `@MainActor final class`. `nonisolated(unsafe)` on monitor/observer storage is documented and safe (deinit-only write-after-last-ref). `Task { @MainActor [weak self] }` for global NSEvent callback (unspecified thread) is correct. `MainActor.assumeIsolated` for workspace observer (delivered on `queue: .main`) is correct with documented rationale. `tearDown()` correctly does not clear `preservedSheetWindowHide`. Double-install guard prevents monitor leaks. No findings. |
| `PanelVisibilityState.swift` | 🔲 | |
| `PanelSheetState.swift` | 🔲 | |
| `NavState.swift` | 🔲 | |

### DesignSystem/
| File | Status | Notes |
|------|--------|-------|
| `DesignTokens.swift` | ⏭️ | Pure UI tokens |
| `PanelViewModifiers.swift` | ✅ | **Clean.** View modifiers only. |
| `RemovalAlertModifier.swift` | ⏭️ | Small modifier |

### GitHub/
| File | Status | Notes |
|------|--------|-------|
| `GitHubHelpers.swift` | ✅ | Root of Finding #1 — free transport functions `ghAPI`, `ghPost`, `cancelRun`, `fetchActionLogs`, `fetchJobLog` (P7) |
| `GitHubTokenCache.swift` | 🔲 | |
| `OAuthService.swift` | ✅ | **Clean.** `@MainActor` isolated. |
| `OAuthSecrets.swift` | 🔲 | |

### Preferences/
| File | Status | Notes |
|------|--------|-------|
| `AppPreferencesStore.swift` | 🔲 | |
| `NotificationPreferences.swift` | 🔲 | |

### Runner/
| File | Status | Notes |
|------|--------|-------|
| `RunnerStore.swift` | ✅ | Finding #7 raw string `nextPollInterval()` (P5); protocols defined inline (P6) |
| `RunnerStore+PollBridge.swift` | ✅ | Finding #2 `ScopeStore.shared` bypass (P7); Finding #13 `.scopes` functional bug |
| `RunnerLifecycleService.swift` | ✅ | Finding #11 singleton, no injection seam (P7) |

### Scope/
| File | Status | Notes |
|------|--------|-------|
| `ScopeStore.swift` | ✅ | Finding #13 confirmed — `.scopes` = all; `.activeScopes` = enabled only |
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
| `FailureHookRunnerUseCase.swift` | ✅ | Finding #52 `ghAPI`/`fetchJobLog` free fn (P7); Finding #53 `JSONDecoder()` per loop (P6). |

### Utilities/
| File | Status | Notes |
|------|--------|-------|
| `WindowGrabber.swift` | ⏭️ | AppKit utility |

### Views/Components/
| File | Status | Notes |
|------|--------|-------|
| `WorkflowContextMenuModifier.swift` | ✅ | Finding #3 three `Task.detached` (P9); Finding #8 `JobContextMenuModifier` free fn calls (P7) |
| `SystemStatsViewModel.swift` | ✅ | **Clean — exemplary.** `@MainActor @Observable`. Generation-stamped sampling loop prevents `stop()→start()` race. `nonisolated(unsafe)` on Mach buffer pointers is documented and correct (deinit-only access). `private static nonisolated func deallocBuffer` correctly shared between `@MainActor` hot path and nonisolated `deinit`. `Task { @MainActor [weak self] }` with explicit annotation. All three `sampleCPU/Memory/Disk` methods correctly isolated. No findings — use as reference implementation for sampling loops. |
| `SystemStatsView.swift` | 🔲 | |
| `DonutStatusView.swift` | ⏭️ | Pure rendering |
| `SparklineView.swift` | ⏭️ | Pure rendering |
| `RingBuffer.swift` | ⏭️ | Data structure |

### Views/Main/
| File | Status | Notes |
|------|--------|-------|
| `InlineJobRowsView.swift` | ✅ | Finding #20 — `jobStatus(for:)` duplicates `ActionRowView.rowStatus`. TODO in file. |
| `ActionRowView.swift` | ✅ | **Clean.** Typed enums, no GCD, no singletons. |
| `PanelContainerView.swift` | 🔲 | |
| `PanelMainView.swift` | ✅ | Finding #19 — `localRunnerStore: LocalRunnerStore = .shared` singleton default (P7) |
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
| `ScopeEditSheet.swift` | ✅ | Finding #54 — 8 `ScopePreferencesStore` static calls in `init`/`confirmSave`, no DI seam (P7) |
| `AddRunnerSheet.swift` | ✅ | Finding #23 — `ScopeType` enum redefined (P6 DRY) |
| `LocalRunnersView.swift` | ✅ | Finding #22 — `localRunnerDotColor(for:)` duplicated |
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
| `BranchSelectorSheet.swift` | ✅ | Finding #9 `ghAPI` free fn (P7); Finding #24 duplication with `RepoSelectorSheet` |
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
| `GitHubURLSessionTransport.swift` | ✅ | **Clean.** One intentional `DispatchQueue.sync {}` documented. |
| `GitHubRateLimitHandler.swift` | 🔲 | |
| `GitHubResponseDecoder.swift` | 🔲 | |
| `GitHubRequestBuilder.swift` | 🔲 | |
| `GitHubConstants.swift` | ⏭️ | Constants |

### Runner/
| File | Status | Notes |
|------|--------|-------|
| `PollResultBuilder.swift` | ✅ | **Clean.** Pure static, all side-effects injected. Typed enums. Finding #16 cosmetic. |
| `WorkflowActionGroupFetch.swift` | ✅ | Finding #50 — `ghAPI` free fn on hot poll path (P7) |
| `RunnerStatusEnricher.swift` | ✅ | Finding #2b singleton as default param; Finding #8b `JSONDecoder()` per loop |
| `RunnerConfigStore.swift` | ✅ | Finding #6b BOM stripping duplicated (P6 DRY) |
| `SaveRunnerEditsUseCase.swift` | ✅ | Finding #7b `LabelsPrerequisiteError` lost at module boundary |
| `ActiveJob.swift` | ✅ | Finding #25 call site |
| `JobStatus.swift` | ✅ | **Clean.** `JobStatus` (6 cases) + `JobConclusion` (9 cases) complete with `.unknown(String)`. `isActive`, `isFailure`, `isHookConclusion` predicates. `ExpressibleByStringLiteral` for tests. |
| `RunnerModel.swift` | ✅ | Clean |
| `RunnerMetrics.swift` | ✅ | Finding #13b — `pgrep`→`ps` pipeline duplicated (P6 DRY) |
| `RunnerModelParser.swift` | ✅ | Finding #6b BOM stripping duplicated (P6 DRY) |
| `LocalRunnerIndex.swift` | ✅ | Clean |
| `RunnerEditDraft.swift` | ⏭️ | Small model |
| `WorkflowActionGroup.swift` | ✅ | Finding #10 — identity-only `==` |
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
| `ScopePreferencesStore.swift` | ✅ | Finding #11b — `UserDefaults.standard` hardcoded (P7) |
| `ScopeEntry.swift` | ⏭️ | Small model |
| `GitHubScope.swift` | ⏭️ | Small model |
| `FailureHookRunnerDependencies.swift` | 🔲 | |

### Services/
| File | Status | Notes |
|------|--------|-------|
| `ProcessRunner.swift` | ✅ | **Clean (by design).** Intentional GCD sync + `Task.detached` — both documented. |
| `LogFetcher.swift` | ✅ | Finding #55/#56 — `fetchJobLog`/`fetchActionLogs` call `ghRaw` free fn (P7); `fetchActionLogs` structured `withTaskGroup` is correct. |

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
| 1 | `GitHubTransportShim.swift` — free transport functions | P7 DI | 🔴 1 | Root cause of #8, #9, #50, #52, #55 |
| 55 | `LogFetcher.swift` — `fetchJobLog`/`fetchActionLogs` → `ghRaw` | P7 DI | 🔴 1 | Part of same transport surface |
| 51 | `AppDelegate+PanelSetup.swift` — triple `RunnerStore` init, orphaned Tasks | P9 | 🔴 1 | Competing poll loops |
| 2 | `RunnerStore+PollBridge.swift` — `ScopeStore.shared` bypass | P7 DI | 🔴 1 | Ignores injected `scopeStore` |
| 13 | `RunnerStore+PollBridge.swift` — `.scopes` returns disabled scopes | P5 bug | 🔴 1 | Functional bug |
| 3 | `WorkflowContextMenuModifier.swift` — 3× `Task.detached` mutations | P9+P7 | 🔴 1 | Silent failure swallowing |
| 50 | `WorkflowActionGroupFetch.swift` — `ghAPI` on hot poll path | P7 DI | 🔴 1 | Every poll cycle |
| 4 | `StepLogView.loadLog` — `Task.detached` + `ScopeStore.shared` | P9+P7 | 🔴 1 | View dealloc risk |
| 54 | `ScopeEditSheet` — 8 `ScopePreferencesStore` static calls | P7 DI | 🟠 2 | |
| 52 | `FailureHookRunnerUseCase` — `ghAPI`/`fetchJobLog` direct | P7 DI | 🟠 2 | Blocked by #1 |
| 5 | `StepLogView` → `LogCopyButton` — GCD round-trip | P2 GCD | 🟠 2 | Trivial fix |
| 6 | `StepLogView` — raw string status comparisons | P5 typed | 🟠 2 | Enums confirmed complete |
| 7 | `RunnerStore.nextPollInterval` — raw string `JobStatus` | P5 typed | 🟠 2 | Disables fast-poll silently |
| 8 | `JobContextMenuModifier` — `fetchJobLog`/`fetchActionLogs` free fn | P7 DI | 🟠 2 | Blocked by #1/#55 |
| 9 | `BranchSelectorSheet.fetchBranchNames` — `ghAPI` free fn | P7 DI | 🟠 2 | Blocked by #1 |
| 53 | `FailureHookRunnerUseCase` — `JSONDecoder()` per loop | P6 | 🟡 3 | Trivial hoist |
| 20 | `InlineJobRowsView.jobStatus` — duplicates `ActionRowView.rowStatus` | P6 DRY | 🟡 3 | TODO in file |
| 10 | `WorkflowActionGroup` — identity-only `==` | P5 | 🟡 3 | |
| 12 | `Keychain.swift` — FIXME(P24) atomicity gap | P24 | 🟡 3 | Tracked FIXME |
| 11 | `RunnerLifecycleService` — singleton, no injection seam | P7 DI | 🟢 4 | Low urgency |

---

## Notable Clean Files (Reference Implementations)

| File | Why It’s Exemplary |
|------|--------------------|
| `SystemStatsViewModel.swift` | Generation-stamped sampling loop; `nonisolated(unsafe)` with correct deinit pattern; `private static nonisolated` dealloc helper |
| `PopoverLifecycleCoordinator.swift` | `Task { @MainActor }` for unspecified-thread callbacks; `MainActor.assumeIsolated` for `queue:.main` callbacks with correct rationale; double-install guard |
| `ProcessRunner.swift` | Intentional GCD/`Task.detached` both fully documented |
| `PollResultBuilder.swift` | Pure static; all side-effects injected; typed enums throughout |
| `ActionRowView.swift` | Clean typed-enum status/conclusion usage — model for #6/#7 fixes |

---

## Next Files to Read (Priority Order)

1. `RunnerBar/Views/Main/PanelContainerView.swift` — 12.9 KB
2. `RunnerBar/Views/Settings/SettingsView.swift` — 10.6 KB
3. `RunnerBarCore/Runner/Runner.swift`
4. `RunnerBarCore/GitHub/GitHubRateLimitHandler.swift`
5. `RunnerBar/Services/FailureHookRunner.swift` + `FailureHookRunnerAdapters.swift`
6. `RunnerBar/App/AppDelegate+StatusItem.swift` + `AppDelegate+StoreSetup.swift` + `AppDelegate+OAuthCallback.swift`
7. `RunnerBarCore/GitHub/GitHubResponseDecoder.swift` + `GitHubRequestBuilder.swift`
8. `RunnerBar/Views/Main/RunnerRowViews.swift` + `PanelContainerView.swift`
