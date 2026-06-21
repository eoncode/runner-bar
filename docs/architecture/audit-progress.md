# Codebase Audit Progress

Tracking file for the principles audit against:
- [Issue #1471](https://github.com/eoncode/runner-bar/issues/1471) + [`project-principles.md`](../architecture/project-principles.md)
- [Issue #1387](https://github.com/eoncode/runner-bar/issues/1387) + [`reach-goal-principles.md`](../principles/reach-goal-principles.md)

Last updated: 2026-06-21 (session 9 — **AUDIT COMPLETE**)

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
| `AppDelegate.swift` | ✅ | **Clean.** `@MainActor` isolated. Singletons accessed only at construction. |
| `AppDelegate+PanelSetup.swift` | ✅ | **Finding #51.** Triple `RunnerStore` init — first two orphaned with live Tasks. |
| `AppDelegate+Navigation.swift` | ✅ | Finding #15 — stale guard on `observable.jobs`. TODO present. |
| `AppDelegate+Polling.swift` | ✅ | **Clean.** One actor-bound `Task` on app lifetime; structured `for await`. |
| `AppDelegate+StatusItem.swift` | ✅ | **Clean.** No GCD, no singletons, no raw strings. |
| `AppDelegate+StoreSetup.swift` | ✅ | **Clean.** `configureGH*` closures are the existing transport injection points — relevant to Finding #1 migration. |
| `AppDelegate+OAuthCallback.swift` | ✅ | **Clean.** `OAuthService.shared` justified (OS delegate, no injection opportunity). |
| `PopoverLifecycleCoordinator.swift` | ✅ | **Clean, exemplary.** |
| `PanelVisibilityState.swift` | ✅ | **Clean, exemplary.** `@MainActor @Observable`; documented regression guard for #377. |
| `PanelSheetState.swift` | ✅ | **Clean.** Correct transient-hide capture/restore pattern. |
| `NavState.swift` | ✅ | **Clean.** Minimal typed enum; history comments intact. |

### DesignSystem/
| File | Status | Notes |
|------|--------|-------|
| `DesignTokens.swift` | ⏭️ | Pure UI tokens |
| `PanelViewModifiers.swift` | ✅ | **Clean.** |
| `RemovalAlertModifier.swift` | ⏭️ | Small modifier |

### GitHub/
| File | Status | Notes |
|------|--------|-------|
| `GitHubHelpers.swift` | ✅ | Root of Finding #1 — free transport functions `ghAPI`, `ghPost`, `cancelRun` (P7) |
| `GitHubTokenCache.swift` | ✅ | **Mostly clean.** `Mutex<String?>` correctly guards concurrent access (P16). Free-function shape intentionally justified in comment. Finding #59 (minor) — `invalidateTokenCache`/`githubToken` are untestable free functions with no injection seam; the comment explicitly argues against namespacing, but a `TokenCacheProtocol` would enable unit tests for sign-out flows. Tier 4 — low priority. |
| `OAuthService.swift` | ✅ | **Clean.** |
| `OAuthSecrets.swift` | ✅ | **Clean.** Committed secret is intentional and documented (open-source native app, standard practice). |

### Preferences/
| File | Status | Notes |
|------|--------|-------|
| `AppPreferencesStore.swift` | ✅ | **Finding #60.** `static let shared` singleton; all `didSet` writes hardcode `UserDefaults.standard` — same P7 pattern as `ScopePreferencesStore` (#11b). Unlike `NotificationPreferences`, there is no `register(into:)` escape hatch for tests. Tier 3. |
| `NotificationPreferences.swift` | ✅ | **Mostly clean.** `static let shared` singleton, but `register(into:)` provides a test-defaults escape hatch — better than `AppPreferencesStore`. Same `UserDefaults.standard` hardcode but partially mitigated. |

### Runner/
| File | Status | Notes |
|------|--------|-------|
| `RunnerStore.swift` | ✅ | Finding #7 raw string `nextPollInterval()` (P5); protocols defined inline (P6) |
| `RunnerStore+PollBridge.swift` | ✅ | Finding #2 `ScopeStore.shared` bypass (P7); Finding #13 `.scopes` functional bug |
| `RunnerLifecycleService.swift` | ✅ | Finding #11 singleton, no injection seam (P7) |

### Scope/
| File | Status | Notes |
|------|--------|-------|
| `ScopeStore.swift` | ✅ | Finding #13 — `.scopes` = all; `.activeScopes` = enabled only |
| `ScopeEntry.swift` | ⏭️ | Small model |

### Services/
| File | Status | Notes |
|------|--------|-------|
| `Keychain.swift` | ✅ | Finding #12 FIXME(P24) atomicity gap |
| `DefaultRunnerLabelsService.swift` | ⏭️ | Small |
| `FailureHookRunner.swift` | ✅ | **Clean.** Thin shim. |
| `FailureHookRunnerAdapters.swift` | ✅ | **Clean, exemplary.** Textbook adapters: one forwarding call per method. |
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
| `SystemStatsViewModel.swift` | ✅ | **Clean, exemplary.** |
| `SystemStatsView.swift` | ✅ | **Clean.** `GlassBadgeContainer`, `HeaderStatsBar`, `DiskPillBadge`, `SparklineMetricView` — pure rendering, no singletons, no GCD. `viewModel.start()`/`stop()` correctly scoped to `onAppear`/`onDisappear`. |
| `DonutStatusView.swift` | ⏭️ | Pure rendering |
| `SparklineView.swift` | ⏭️ | Pure rendering |
| `RingBuffer.swift` | ⏭️ | Data structure |

### Views/Main/
| File | Status | Notes |
|------|--------|-------|
| `InlineJobRowsView.swift` | ✅ | Finding #20 — `jobStatus(for:)` duplicates `ActionRowView.rowStatus`. Self-annotated TODO+NOSONAR present. |
| `ActionRowView.swift` | ✅ | **Clean.** Typed enums, no GCD, no singletons. Reference for #6/#7 fixes. |
| `PanelContainerView.swift` | ✅ | **Clean, exemplary.** |
| `PanelMainView.swift` | ✅ | Finding #19 — `localRunnerStore: LocalRunnerStore = .shared` singleton default (P7) |
| `RunnerRowViews.swift` | ✅ | Finding #58 (minor) — `normaliseArch(_:)` raw string switch; display-only labels. |
| `WorkflowActionGroup+Progress.swift` | ✅ | Finding #25 — `progressFraction` done-semantics inconsistency |
| `PanelHeaderView.swift` | ✅ | **Clean.** Pure layout; `onSelectSettings` correctly injected. |
| `PanelMainView+Subviews.swift` | ⏭️ | Small |

### Views/Runner/
| File | Status | Notes |
|------|--------|-------|
| `RunnerViewModel.swift` | ⏭️ | Small |

### Views/Settings/
| File | Status | Notes |
|------|--------|-------|
| `ScopeEditSheet.swift` | ✅ | Finding #54 — 8 `ScopePreferencesStore` static calls (P7) |
| `AddRunnerSheet.swift` | ✅ | Finding #23 — `ScopeType` enum redefined (P6 DRY) |
| `LocalRunnersView.swift` | ✅ | Finding #22 — `localRunnerDotColor(for:)` duplicated |
| `RunnerDetailSheet.swift` | ✅ | Finding #22 call site |
| `AddRunnerSheet+FormFields.swift` | ✅ | Finding #23 call site |
| `SettingsView.swift` | ✅ | Finding #57 — `@State` singleton prefs + `OAuthService.onCompletion` global mutation (P7) |
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
| `main.swift` | ⏭️ | Entry point — `NSApplication.shared.run()`; no logic to audit |
| `Exports.swift` | ⏭️ | Re-exports only |

---

## RunnerBarCore (core target)

### GitHub/
| File | Status | Notes |
|------|--------|-------|
| `GitHubTransportShim.swift` | ✅ | Root of Finding #1 — free functions defined here |
| `GitHubURLSessionTransport.swift` | ✅ | **Clean.** One intentional `DispatchQueue.sync {}` documented. |
| `GitHubRateLimitHandler.swift` | ✅ | **Clean, exemplary.** |
| `GitHubResponseDecoder.swift` | ✅ | **Clean, exemplary.** |
| `GitHubRequestBuilder.swift` | ✅ | **Clean.** Module-level CharacterSet constant; S3 redirect + Bearer-stripping documented. |
| `GitHubConstants.swift` | ⏭️ | Constants |

### Runner/
| File | Status | Notes |
|------|--------|-------|
| `PollResultBuilder.swift` | ✅ | **Clean, exemplary.** Pure static; all side-effects injected; typed enums. |
| `WorkflowActionGroupFetch.swift` | ✅ | Finding #50 — `ghAPI` free fn on hot poll path (P7) |
| `RunnerStatusEnricher.swift` | ✅ | Finding #2b singleton as default param; Finding #8b `JSONDecoder()` per loop |
| `RunnerConfigStore.swift` | ✅ | Finding #6b BOM stripping duplicated (P6 DRY) |
| `SaveRunnerEditsUseCase.swift` | ✅ | Finding #7b `LabelsPrerequisiteError` lost at module boundary |
| `ActiveJob.swift` | ✅ | Finding #25 call site |
| `JobStatus.swift` | ✅ | **Clean.** `JobStatus` (6 cases) + `JobConclusion` (9 cases) complete with `.unknown(String)`. |
| `RunnerModel.swift` | ✅ | Clean |
| `RunnerMetrics.swift` | ✅ | Finding #13b — `pgrep`→`ps` pipeline duplicated (P6 DRY) |
| `RunnerModelParser.swift` | ✅ | Finding #6b BOM stripping duplicated (P6 DRY) |
| `LocalRunnerIndex.swift` | ✅ | Clean |
| `RunnerEditDraft.swift` | ⏭️ | Small model |
| `WorkflowActionGroup.swift` | ✅ | Finding #10 — identity-only `==` |
| `Runner.swift` | ✅ | **Clean.** `CodingKeys` excludes post-decode field; `copying(metrics:)` immutable-mutation. |
| `RunnerConfigStoreProtocol.swift` | ⏭️ | Protocol definition |
| `RunnerLabelsServiceProtocol.swift` | ⏭️ | Protocol definition |
| `RunnerStatusEnricherProtocol.swift` | ⏭️ | Protocol definition |
| `RunnerProxyStoreProtocol.swift` | ⏭️ | Protocol definition |
| `RunnerProxyStoreError.swift` | ⏭️ | Small |
| `RunnerProxyConfig.swift` | ⏭️ | Small model |
| `RunnerStatus.swift` | ⏭️ | Small model |
| `AggregateStatus.swift` | ⏭️ | Small model |
| `CommitResult.swift` | ⏭️ | Small model |
| `RunnerConfig.swift` | ⏭️ | Small model |

### Scope/
| File | Status | Notes |
|------|--------|-------|
| `ScopePreferencesStore.swift` | ✅ | Finding #11b — `UserDefaults.standard` hardcoded (P7) |
| `ScopeEntry.swift` | ⏭️ | Small model |
| `GitHubScope.swift` | ⏭️ | Small model |
| `FailureHookRunnerDependencies.swift` | ✅ | **Clean, exemplary.** Protocol surface minimal; `@MainActor` at protocol level. |

### Services/
| File | Status | Notes |
|------|--------|-------|
| `ProcessRunner.swift` | ✅ | **Clean (by design).** |
| `LogFetcher.swift` | ✅ | Finding #55/#56 — `fetchJobLog`/`fetchActionLogs` call `ghRaw` free fn (P7). |

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

## ✅ AUDIT COMPLETE — All Confirmed Findings (Ranked by Priority)

| # | File | Principle | Tier | Notes |
|---|------|-----------|------|-------|
| 1 | `GitHubTransportShim.swift` — free transport fns | P7 DI | 🔴 1 | Root cause of #8, #9, #50, #52, #55 |
| 55 | `LogFetcher.swift` — `fetchJobLog`/`fetchActionLogs` → `ghRaw` | P7 DI | 🔴 1 | Same transport surface |
| 51 | `AppDelegate+PanelSetup.swift` — triple `RunnerStore` init | P9 | 🔴 1 | Competing poll loops |
| 2 | `RunnerStore+PollBridge.swift` — `ScopeStore.shared` bypass | P7 DI | 🔴 1 | Ignores injected `scopeStore` |
| 13 | `RunnerStore+PollBridge.swift` — `.scopes` returns disabled scopes | P5 bug | 🔴 1 | Functional bug |
| 3 | `WorkflowContextMenuModifier.swift` — 3× `Task.detached` mutations | P9+P7 | 🔴 1 | Silent failure swallowing |
| 50 | `WorkflowActionGroupFetch.swift` — `ghAPI` on hot poll path | P7 DI | 🔴 1 | Every poll cycle |
| 4 | `StepLogView.loadLog` — `Task.detached` + `ScopeStore.shared` | P9+P7 | 🔴 1 | View dealloc risk |
| 57 | `SettingsView` — `@State` singleton prefs + `OAuthService.onCompletion` | P7 DI | 🟠 2 | |
| 54 | `ScopeEditSheet` — 8 `ScopePreferencesStore` static calls | P7 DI | 🟠 2 | |
| 52 | `FailureHookRunnerUseCase` — `ghAPI`/`fetchJobLog` direct | P7 DI | 🟠 2 | Blocked by #1 |
| 5 | `StepLogView` → `LogCopyButton` — GCD round-trip | P2 GCD | 🟠 2 | Trivial fix |
| 6 | `StepLogView` — raw string status comparisons | P5 typed | 🟠 2 | |
| 7 | `RunnerStore.nextPollInterval` — raw string `JobStatus` | P5 typed | 🟠 2 | Disables fast-poll silently |
| 8 | `JobContextMenuModifier` — free fn calls | P7 DI | 🟠 2 | Blocked by #1/#55 |
| 9 | `BranchSelectorSheet` — `ghAPI` free fn | P7 DI | 🟠 2 | Blocked by #1 |
| 53 | `FailureHookRunnerUseCase` — `JSONDecoder()` per loop | P6 | 🟡 3 | Trivial hoist |
| 20 | `InlineJobRowsView` — duplicates `ActionRowView.rowStatus` | P6 DRY | 🟡 3 | Self-annotated TODO present |
| 60 | `AppPreferencesStore` — `UserDefaults.standard` hardcoded, no test escape hatch | P7 DI | 🟡 3 | No `register(into:)` unlike `NotificationPreferences` |
| 10 | `WorkflowActionGroup` — identity-only `==` | P5 | 🟡 3 | |
| 12 | `Keychain` — FIXME(P24) atomicity gap | P24 | 🟡 3 | Tracked FIXME |
| 58 | `RunnerRowViews` — `normaliseArch` raw string switch | P5 typed | 🟢 4 | Display-only labels, open-ended source |
| 59 | `GitHubTokenCache` — `invalidateTokenCache`/`githubToken` free fns, no injection seam | P7 DI | 🟢 4 | Justified in comment; minor testability gap |
| 11 | `RunnerLifecycleService` — singleton, no injection seam | P7 DI | 🟢 4 | |

---

## Notable Clean Files (Reference Implementations)

| File | Why It's Exemplary |
|------|-------------------|
| `SystemStatsViewModel.swift` | Generation-stamped loop; `nonisolated(unsafe)` with correct deinit pattern |
| `PopoverLifecycleCoordinator.swift` | `Task { @MainActor }` for unspecified-thread callbacks; `MainActor.assumeIsolated` |
| `PanelContainerView.swift` | Timer + `Task { @MainActor }` for NSWindow.sheets; transient-hide invariant |
| `PanelVisibilityState.swift` | `@MainActor @Observable`; documented regression guard; explicit `init()` for signature safety |
| `GitHubRateLimitHandler.swift` | `RateLimitActor` with generation-stamped didFire; `snapshot()` single-hop |
| `GitHubResponseDecoder.swift` | Rate-limit vs permission-denied 403 distinction; `rateLimiter` no-default intentional |
| `GitHubRequestBuilder.swift` | Module-level CharacterSet constant; S3 redirect Bearer-stripping note |
| `ProcessRunner.swift` | Intentional GCD/`Task.detached` both fully documented |
| `PollResultBuilder.swift` | Pure static; all side-effects injected; typed enums throughout |
| `ActionRowView.swift` | Clean typed-enum status/conclusion usage — model for #6/#7 fixes |
| `FailureHookRunnerAdapters.swift` | Textbook adapters: one forwarding call per method, no logic |
| `FailureHookRunnerDependencies.swift` | Protocol surface minimal; `@MainActor` propagated at protocol level |
| `Runner.swift` | `CodingKeys` excludes post-decode field; `copying(metrics:)` immutable-mutation |

---

## Key Architecture Note: Transport Injection Point

`AppDelegate+StoreSetup.swift` calls `configureGHAPI`, `configureGHRaw`, `configureGHAPIPaginated`, and `configureGHToken` — the current closure-based injection points. Any `GitHubTransportProtocol` migration (Finding #1) will replace these four closure registrations with constructor injection.
