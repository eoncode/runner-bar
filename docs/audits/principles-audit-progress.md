# Principles Audit Progress Tracker

Tracking file for the full codebase audit against
[project-principles.md](../architecture/project-principles.md) and
[reach-goal-principles.md](../principles/reach-goal-principles.md),
as requested in issues [#1471](https://github.com/eoncode/runner-bar/issues/1471)
and [#1387](https://github.com/eoncode/runner-bar/issues/1387).

Collected findings are posted to issue [#1507](https://github.com/eoncode/runner-bar/issues/1507).

---

## Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Checked — no findings |
| 🔴 | Checked — finding(s) logged |
| ⬜ | Not yet checked |

---

## Sources/RunnerBarCore

### GitHub/
| File | Status | Findings |
|------|--------|---------|
| `GitHubTransportShim.swift` (free fns: `ghAPI`, `ghPost`, `ghRaw`, `cancelRun`) | 🔴 | #1 — no protocol seam; all consumers call free fns directly (P7) |
| `GitHubModels.swift` | ✅ | Clean |
| `GitHubWorkflowModels.swift` | ✅ | Typed models correct |
| `JobStatus.swift` / `JobConclusion.swift` | ✅ | Enums defined; under-used at call sites (see #6, #7) |

### Runner/
| File | Status | Findings |
|------|--------|---------|
| `RunnerStore.swift` | 🔴 | #7 — `nextPollInterval` uses raw `String` instead of `JobStatus` enum (P5) |
| `RunnerStore+PollBridge.swift` | 🔴 | #2 — `buildJobState`/`buildGroupState` bypass injected `self.scopeStore`, call `ScopeStore.shared.scopes` directly (P7) |
| `RunnerViewModel.swift` | ✅ | Clean push target; no violations found |
| `LocalRunnerStore.swift` | ✅ | Uses configure(viewModel:) correctly |
| `RunnerLifecycleService.swift` | 🔴 | #11 — singleton `shared` with private init; no injection seam (P7, low urgency) |

### Scope/
| File | Status | Findings |
|------|--------|---------|
| `ScopeStore.swift` | ✅ | `.scopes` vs `.activeScopes` semantic difference noted for #13 |

### Services/
| File | Status | Findings |
|------|--------|---------|
| `LogFetcher.swift` (`fetchJobLog`, `fetchActionLogs`) | 🔴 | Part of free-fn transport layer (#1); `fetchActionLogs` uses `TaskGroup` correctly but calls `ghRaw` directly (P7) |
| `ProcessRunner.swift` | ✅ | Intentional `Task.detached` for timeout guard — documented and correct (P9 compliant) |

### Utilities/
| File | Status | Findings |
|------|--------|---------|
| `Keychain.swift` | 🔴 | #12 — existing `FIXME(P24)` atomicity gap between `SecItemUpdate/Add` and `invalidateTokenCache()` (low risk) |
| Other utilities | ✅ | No violations found |

---

## Sources/RunnerBar

### App/
| File | Status | Findings |
|------|--------|---------|
| `AppDelegate.swift` | ✅ | `@MainActor` isolation correct; no violations |
| `AppDelegate+PanelSetup.swift` | 🔴 | **#50 NEW** — `RunnerStore` initialized **three times** in `setupSubscriptions()` (duplicate `runnerStore = RunnerStore(…)` calls with stale log prefix); second and third inits create and immediately discard competing poll-loop actors. Also: KVO `DispatchQueue.main.async` hop for `preferredContentSize` could use `Task { @MainActor in }` (P2, minor) |
| `AppDelegate+Navigation.swift` | ✅ | Navigation routing clean |
| `AppDelegate+OAuthCallback.swift` | ✅ | Small; no violations |
| `AppDelegate+Polling.swift` | ✅ | `signOutTask` retention correct |
| `AppDelegate+StatusItem.swift` | ✅ | No violations |
| `AppDelegate+StoreSetup.swift` | ⬜ | Not yet read |
| `NavState.swift` | ✅ | Value type, no violations |
| `PanelSheetState.swift` | ✅ | No violations |
| `PanelVisibilityState.swift` | ✅ | No violations |
| `PopoverLifecycleCoordinator.swift` | ⬜ | Not yet read |

### Views/
| File | Status | Findings |
|------|--------|---------|
| `StepLogView.swift` | 🔴 | #43 — `Task.detached` fire-and-forget in `loadLog` (P9); #44 — `ScopeStore.shared` fallback (P7); #45 — raw string status comparisons (P5); #46 — `DispatchQueue.global` hop in `LogCopyButton` fetch closure (P2) |
| `WorkflowContextMenuModifier.swift` | 🔴 | #47 — three `Task.detached` fire-and-forget mutations (P9); #48 — free fn `ghPost`/`cancelRun` direct calls (P7) |
| `JobContextMenuModifier.swift` | 🔴 | #48/#8 — free fn `fetchJobLog`/`fetchActionLogs` direct calls (P7) |
| `BranchSelectorSheet.swift` | 🔴 | #49 — `ghAPI` free fn call in `fetchBranchNames` (P7) |
| `RunnerRowView.swift` | ✅ | No violations found |
| `WorkflowListView.swift` | ✅ | No violations found |
| `MainView.swift` | ✅ | No violations found |
| Other Views/* | ⬜ | Not yet fully enumerated |

### GitHub/ (RunnerBar layer)
| File | Status | Findings |
|------|--------|---------|
| *(directory not yet enumerated)* | ⬜ | Not yet checked |

### Preferences/
| File | Status | Findings |
|------|--------|---------|
| `AppPreferencesStore.swift` | ✅ | Injection path used correctly in `AppDelegate+PanelSetup` |
| Other prefs files | ⬜ | Not yet fully checked |

### Runner/ (RunnerBar UI layer)
| File | Status | Findings |
|------|--------|---------|
| *(directory not yet enumerated)* | ⬜ | Not yet checked |

### Scope/ (RunnerBar UI layer)
| File | Status | Findings |
|------|--------|---------|
| *(directory not yet enumerated)* | ⬜ | Not yet checked |

### Services/ (RunnerBar layer)
| File | Status | Findings |
|------|--------|---------|
| *(directory not yet enumerated)* | ⬜ | Not yet checked |

### UseCases/
| File | Status | Findings |
|------|--------|---------|
| *(directory not yet enumerated)* | ⬜ | Not yet checked — key target for #3 fix (WorkflowActionsUseCase) |

### DesignSystem/
| File | Status | Findings |
|------|--------|---------|
| *(directory not yet enumerated)* | ⬜ | Low priority; unlikely to have concurrency/DI violations |

### Utilities/ (RunnerBar layer)
| File | Status | Findings |
|------|--------|---------|
| *(directory not yet enumerated)* | ⬜ | Not yet checked |

---

## Files Not Yet Checked (Priority Order)

1. `Sources/RunnerBar/UseCases/` — high priority; home for mutation use-cases (#3 fix target)
2. `Sources/RunnerBar/GitHub/` — may contain additional transport call sites
3. `Sources/RunnerBar/Runner/` — may contain additional raw-string comparisons (#6/#7 pattern)
4. `Sources/RunnerBar/Scope/` — may contain ScopeStore call sites
5. `Sources/RunnerBar/Services/` — may contain additional service singletons
6. `Sources/RunnerBar/App/AppDelegate+StoreSetup.swift`
7. `Sources/RunnerBar/App/PopoverLifecycleCoordinator.swift`
8. `Sources/RunnerBar/Preferences/` (remaining files)
9. `Sources/RunnerBar/Views/` (remaining views not yet checked)
10. `Sources/RunnerBar/DesignSystem/` — lowest priority
11. `Sources/RunnerBarCore/GitHub/` (remaining models/utilities)
12. `Sources/RunnerBarCore/Utilities/` (remaining utilities)
13. `Tests/` — verify test coverage gaps align with DI findings

---

## Confirmed Findings Index

| # | File | Principle | Tier |
|---|------|-----------|------|
| 1 | `GitHubTransportShim` + 5 consumers | P7 DI | 🔴 Critical |
| 2 | `RunnerStore+PollBridge` — `ScopeStore.shared` bypass | P7 DI | 🔴 Critical |
| 3 | `WorkflowContextMenuModifier` — 3× `Task.detached` mutations | P9 + P7 | 🔴 High |
| 4 | `StepLogView.loadLog` — `Task.detached` + `ScopeStore.shared` fallback | P9 + P7 | 🔴 High |
| 5 | `StepLogView` → `LogCopyButton` — gratuitous `DispatchQueue.global` hop | P2 | 🟠 Medium |
| 6 | `StepLogView.stepStatusLabel/Color` — raw string comparisons | P5 | 🟠 Medium |
| 7 | `RunnerStore.nextPollInterval` — raw string `JobStatus` comparisons | P5 | 🟠 Medium |
| 8 | `JobContextMenuModifier` — free fn `fetchJobLog`/`fetchActionLogs` | P7 DI | 🟡 Blocked by #1 |
| 9 | `BranchSelectorSheet.fetchBranchNames` — free fn `ghAPI` | P7 DI | 🟡 Blocked by #1 |
| 10 | `RunnerStore.applyFetchResult` — dual responsibility | P6 SRP | 🟢 Low |
| 11 | `RunnerLifecycleService.shared` — singleton, no injection seam | P7 DI | 🟢 Low |
| 12 | `Keychain.save` — FIXME(P24) atomicity gap | P24 | 🟢 Existing |
| 13 | `.scopes` vs `.activeScopes` — semantic discrepancy | P5 | 🟡 Verify |
| 50 | `AppDelegate+PanelSetup.setupSubscriptions` — `RunnerStore` init × 3 | P6/P9 | 🔴 **NEW High** |

---

*Last updated: 2026-06-21. Next: enumerate `UseCases/`, `Runner/`, `GitHub/` directories.*
