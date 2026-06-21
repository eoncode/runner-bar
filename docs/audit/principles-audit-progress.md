# Principles Audit — Progress Tracker

> **Task:** Identify violations of project principles — not bugs.  
> **Principles sources:** [project-principles.md](../architecture/project-principles.md) · [reach-goal-principles.md](../principles/reach-goal-principles.md)  
> **Tracking issue for findings (ranked):** [#1505](https://github.com/eoncode/runner-bar/issues/1505)  
> **Scope issues:** [#1471](https://github.com/eoncode/runner-bar/issues/1471) · [#1387](https://github.com/eoncode/runner-bar/issues/1387)  
> **Last updated:** 2026-06-21 — **AUDIT COMPLETE ✔️** (all production files read)

---

## ✅ FULLY READ

### Sources/RunnerBarCore/GitHub/
- [x] GitHubConstants.swift — ✅ clean
- [x] GitHubRateLimitHandler.swift — ⚠️ FINDING #18: module-level singleton `rateLimitActor`
- [x] GitHubRequestBuilder.swift — ✅ clean
- [x] GitHubResponseDecoder.swift — ✅ clean
- [x] GitHubTransportShim.swift — ✅ clean
- [x] GitHubURLSessionTransport.swift — ⚠️ FINDING #11: all transport as free module-level functions; two module-level globals

### Sources/RunnerBarCore/Runner/
- [x] ActiveJob.swift — ⚠️ FINDING #15: 12-param init with NOSONAR suppression
- [x] AggregateStatus.swift — ✅ clean
- [x] CommitResult.swift — ✅ clean
- [x] JobStatus.swift — ⚠️ FINDING #16: manual rawValue + Codable + init(rawString:) triplication
- [x] LocalRunnerIndex.swift — ✅ clean
- [x] PollResultBuilder.swift — ⚠️ FINDING #14: Set eviction not FIFO
- [x] PollResults.swift — ✅ clean
- [x] Runner.swift — ✅ clean
- [x] RunnerConfig.swift — ✅ clean
- [x] RunnerConfigStore.swift — ✅ clean
- [x] RunnerConfigStoreProtocol.swift — ✅ clean
- [x] RunnerEditDraft.swift (Core) — ✅ clean
- [x] RunnerLabelsServiceProtocol.swift — ✅ clean
- [x] RunnerMetrics.swift — ⚠️ FINDING S2b: free async functions, no protocol
- [x] RunnerModel.swift — ⚠️ FINDING #10: 18-param init with NOSONAR suppression
- [x] RunnerModelParser.swift — ✅ clean
- [x] RunnerProxyConfig.swift — ✅ clean
- [x] RunnerProxyStoreError.swift — ✅ clean
- [x] RunnerProxyStoreProtocol.swift — ✅ clean
- [x] RunnerStatus.swift — ✅ clean
- [x] RunnerStatusEnricher.swift — ⚠️ FINDING #13: `static let shared` singleton bypasses DI
- [x] RunnerStatusEnricherProtocol.swift — ✅ clean
- [x] SaveRunnerEditsUseCase.swift — ✅ clean
- [x] WorkflowActionGroup.swift — ⚠️ FINDINGS #12, #17: Equatable skips fields; silent .completed fallthrough
- [x] WorkflowActionGroupFetch.swift — ⚠️ FINDING #6: file-scoped shared JSONDecoder

### Sources/RunnerBarCore/Scope/
- [x] FailureHookRunnerDependencies.swift — ✅ clean
- [x] GitHubScope.swift — ✅ clean
- [x] ScopeEntry.swift — ✅ clean
- [x] ScopePreferencesStore.swift — ⚠️ FINDINGS #1, #3: raw UserDefaults; no actor isolation

### Sources/RunnerBarCore/Utilities/
- [x] AnyJSON.swift — ✅ clean
- [x] FormatElapsed.swift — ✅ clean
- [x] GitHubURLHelpers.swift — ✅ clean
- [x] ISO8601DateParser.swift — ✅ clean
- [x] Logger.swift — ⚠️ FINDING #8: single "general" category across all subsystems
- [x] SystemStats.swift — ✅ clean

### Sources/RunnerBarCore/Services/
- [x] LogFetcher.swift — ⚠️ FINDING S2a: free functions; FileManager not injectable
- [x] ProcessRunner.swift — ⚠️ FINDING #4: last `DispatchQueue.sync` in production path (intentional, documented)

### Sources/RunnerBar/App/
- [x] AppDelegate.swift — ⚠️ FINDINGS: `AnyView` type erasure in `wrapEnv`; IUO `runnerStore!`; **FINDING #26**: `DispatchQueue.main.async` in `openPanel()` for `panelSheetState.restoreTransientHideStateIfNeeded()` (Principle 2 — GCD remnant in the open path)
- [x] AppDelegate+Navigation.swift — ✅ clean
- [x] AppDelegate+OAuthCallback.swift — ✅ clean
- [x] AppDelegate+PanelSetup.swift — ⚠️ FINDING #21: RunnerStore constructed 3× (first two orphaned); FINDING #22: `DispatchQueue.main.async` in KVO callback
- [x] AppDelegate+Polling.swift — ✅ clean
- [x] AppDelegate+StatusItem.swift — ✅ clean
- [x] AppDelegate+StoreSetup.swift — ✅ clean
- [x] NavState.swift — ✅ clean
- [x] PanelSheetState.swift — ✅ clean
- [x] PanelVisibilityState.swift — ✅ clean
- [x] PopoverLifecycleCoordinator.swift — ✅ clean
- [x] main.swift — ✅ clean
- [x] Exports.swift — ✅ clean

### Sources/RunnerBar/DesignSystem/
- [x] DesignTokens.swift — ⚠️ FINDING S2e: `RBStatus` duplicates status domain concepts
- [x] PanelViewModifiers.swift — ✅ clean
- [x] RemovalAlertModifier.swift — ✅ clean

### Sources/RunnerBar/GitHub/
- [x] GitHubHelpers.swift — ✅ clean
- [x] GitHubTokenCache.swift — ⚠️ FINDING S2c: `githubToken()` / `invalidateTokenCache()` free functions, not injectable
- [x] OAuthSecrets.swift — ⚠️ FINDING S2d: 40-line justification block for 2-line enum
- [x] OAuthService.swift — ⚠️ FINDING #23: `static let shared` singleton, no DI protocol; `NSWorkspace.shared.open` directly inside service

### Sources/RunnerBar/Preferences/
- [x] AppPreferencesStore.swift — ⚠️ FINDING #2: raw `UserDefaults.standard` string keys (confirmed)
- [x] NotificationPreferences.swift — ✅ clean

### Sources/RunnerBar/Runner/
- [x] CommitRunnerEdit.swift — ✅ clean
- [x] LocalRunnerStore.swift — ✅ clean
- [x] PollLoopCoordinator.swift — ✅ clean (`@unchecked Sendable` with documented sign-off)
- [x] RunnerEditDraft.swift — ✅ clean
- [x] RunnerLifecycleService.swift — ⚠️ FINDING #24: `static let shared` singleton, no DI protocol; `FileManager.default` directly
- [x] RunnerProxyStore.swift — ✅ clean
- [x] RunnerStore+InstallPathMap.swift — ✅ clean
- [x] RunnerStore+PollBridge.swift — ⚠️ FINDING #19: bypasses injected `scopeStore`, calls `ScopeStore.shared.scopes` directly (confirmed)
- [x] RunnerStore+PollLoop.swift — ✅ clean
- [x] RunnerStore.swift — ✅ clean

### Sources/RunnerBar/Scope/
- [x] ScopeEntry.swift (re-export) — ✅ clean
- [x] ScopeStore.swift — ⚠️ FINDING #25: `var scopes` legacy accessor is documented-stale dead public API

### Sources/RunnerBar/Services/
- [x] DefaultRunnerLabelsService.swift — ✅ clean
- [x] FailureHookRunner.swift — ✅ clean
- [x] FailureHookRunnerAdapters.swift — ✅ clean
- [x] Keychain.swift — ⚠️ FINDING #9: non-atomic SecItem + cache invalidation (FIXME(P24) in file)
- [x] LoginItem.swift — ✅ clean
- [x] TerminalLauncher.swift — ✅ clean

### Sources/RunnerBar/UseCases/
- [x] FailureHookRunnerUseCase.swift — ⚠️ FINDING #5: `Task.detached` fire-and-forget (documented intent)

### Sources/RunnerBar/Utilities/
- [x] WindowGrabber.swift — ✅ clean

### Sources/RunnerBar/Views/ (previous sessions)
- [x] ~20+ view files — findings previously logged

### Tests/RunnerBarCoreTests/ (previous sessions)
- [x] All test files read

### Tests/RunnerBarUITests/
- [x] RunnerBarUITests.swift — ⚠️ **FINDING #27**: `Thread.sleep(forTimeInterval: 0.5)` in `setUp()` — blocking sleep in test setup violates Principle 2 (no blocking thread sleeps; use `XCTNSPredicateExpectation` or `waitForExistence` instead). Also `continueAfterFailure = false` is correct but `firstRunnerRow()` iterates all buttons with `allElementsBoundByIndex` — O(n) AX traversal with no index bound, can be slow on large hierarchies.

---

## 🏁 AUDIT COMPLETE

All `Sources/` and `Tests/` files are now read. No remaining unread territory.

---

## FINDINGS LOG — all sessions

All findings ranked in [#1505](https://github.com/eoncode/runner-bar/issues/1505).

| # | File | Principle | Finding | Severity |
|---|------|-----------|---------|----------|
| 1 | `ScopePreferencesStore.swift` | P3 | Raw `UserDefaults` string keys instead of `Codable` | High |
| 2 | `AppPreferencesStore.swift` | P3 | Raw `UserDefaults` string keys instead of `Codable` | High |
| 3 | `ScopePreferencesStore.swift` | P7 + P16 | Static methods only, no actor isolation | High |
| 4 | `ProcessRunner.swift` | P2 + P9 | Last `DispatchQueue.sync` in production path (documented sign-off) | Medium |
| 5 | `FailureHookRunnerUseCase.swift` | P9 | `Task.detached` fire-and-forget (documented intent) | Medium |
| 6 | `WorkflowActionGroupFetch.swift` | P4 + P17 | File-scoped shared `JSONDecoder` across concurrent calls | Medium |
| 7 | `AppDelegate.swift` | P8 | Business logic in app layer | High |
| 8 | `Logger.swift` | P15 + P16 | Single `"general"` log category across all subsystems | Low |
| 9 | `Keychain.swift` | P10 | Non-atomic SecItem mutation + cache invalidation (FIXME(P24) in file) | Medium |
| 10 | `RunnerModel.swift` | P6 + P8 | 18-param init with `// NOSONAR` suppression | Medium |
| 11 | `GitHubURLSessionTransport.swift` | P7 + P16 | All transport as free module-level functions; two module-level globals | High |
| 12 | `WorkflowActionGroup.swift` | P6 | `Equatable` skips all fields except `id` | Medium |
| 13 | `RunnerStatusEnricher.swift` | P7 | `static let shared` singleton bypasses DI | Medium |
| 14 | `PollResultBuilder.swift` | P5 | `Set` eviction is arbitrary, not FIFO — can re-fire failure hook | Medium |
| 15 | `ActiveJob.swift` | P6 + P8 | 12-param init with `// NOSONAR` suppression | Medium |
| 16 | `JobStatus.swift` | P6 | Manual `rawValue` + `Codable` + `init(rawString:)` triplication | Medium |
| 17 | `WorkflowActionGroup.swift` | P8 | Silent `.completed` fallthrough for loading state; unresolved `// TODO:` | Medium |
| 18 | `GitHubRateLimitHandler.swift` | P7 + P16 | Module-level singleton `rateLimitActor` bypasses full DI | Medium |
| 19 | `RunnerStore+PollBridge.swift` | P4 + P7 | Bypasses injected `scopeStore`; calls `ScopeStore.shared.scopes` directly | High |
| 20 | `AppDelegate+PanelSetup.swift` | P8 + P16 | `RunnerStore` constructed 3×; first two instances orphaned with live Tasks | High |
| 21 | `AppDelegate+PanelSetup.swift` | P2 | `DispatchQueue.main.async` in KVO callback | Low |
| 22 | `OAuthService.swift` | P7 + P4 | `static let shared` singleton; no DI protocol; `NSWorkspace.shared.open` directly | Medium |
| 23 | `RunnerLifecycleService.swift` | P7 + P4 | `static let shared` singleton; no DI protocol; `FileManager.default` directly | Medium |
| 24 | `ScopeStore.swift` | P6 | `var scopes` documented-stale legacy accessor kept on public surface | Low |
| 25 | `AppDelegate.swift` | P2 | `DispatchQueue.main.async` in `openPanel()` for sheet-state restore | Low |
| 26 | `RunnerBarUITests.swift` | P2 | `Thread.sleep(forTimeInterval: 0.5)` in `setUp()`; `allElementsBoundByIndex` O(n) AX traversal with no bound | Low |
| S2a | `LogFetcher.swift` | Reach — testability | Free functions; `FileManager` not injectable | Medium |
| S2b | `RunnerMetrics.swift` | Reach — testability | Free async functions; no protocol | Medium |
| S2c | `GitHubTokenCache.swift` | Reach — testability | `githubToken()` / `invalidateTokenCache()` free functions, not injectable | Medium |
| S2d | `OAuthSecrets.swift` | Reach — lean code | 40-line justification block for 2-line enum | Low |
| S2e | `DesignTokens.swift` | P — DRY | `RBStatus` duplicates status domain expressed by `JobStatus`/`AggregateStatus` | Low |
