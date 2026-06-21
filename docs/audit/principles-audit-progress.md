# Principles Audit — Progress Tracker

> **Task:** Identify violations of project principles — not bugs.  
> **Principles sources:** [project-principles.md](../architecture/project-principles.md) · [reach-goal-principles.md](../principles/reach-goal-principles.md)  
> **Tracking issue for findings (ranked):** [#1505](https://github.com/eoncode/runner-bar/issues/1505)  
> **Scope issues:** [#1471](https://github.com/eoncode/runner-bar/issues/1471) · [#1387](https://github.com/eoncode/runner-bar/issues/1387)  
> **Last updated:** 2026-06-21

---

## ✅ FULLY READ

### Sources/RunnerBarCore/GitHub/
- [x] GitHubConstants.swift — ✅ clean
- [x] GitHubRateLimitHandler.swift — ✅ clean
- [x] GitHubRequestBuilder.swift — ✅ clean
- [x] GitHubResponseDecoder.swift — ✅ clean
- [x] GitHubTransportShim.swift — ✅ clean (previous sessions)
- [x] GitHubURLSessionTransport.swift — ✅ clean (previous sessions)

### Sources/RunnerBarCore/Runner/
- [x] ActiveJob.swift — ✅ clean (previous sessions)
- [x] AggregateStatus.swift — ✅ clean
- [x] CommitResult.swift — ✅ tiny value type, no violations
- [x] JobStatus.swift — ✅ clean (previous sessions)
- [x] LocalRunnerIndex.swift — ✅ clean, injectable via init
- [x] PollResultBuilder.swift — ✅ clean (previous sessions)
- [x] PollResults.swift — ✅ clean
- [x] Runner.swift — ✅ clean; `copying(metrics:)` pattern correct
- [x] RunnerConfig.swift — not yet read (small, low risk)
- [x] RunnerConfigStore.swift — ✅ clean (previous sessions)
- [x] RunnerConfigStoreProtocol.swift — not yet read (protocol stub)
- [x] RunnerEditDraft.swift (Core) — not yet read
- [x] RunnerLabelsServiceProtocol.swift — not yet read (protocol stub)
- [x] RunnerMetrics.swift — ⚠️ FINDING: free async functions, not injectable (see #1505)
- [x] RunnerModel.swift — ✅ clean (previous sessions)
- [x] RunnerModelParser.swift — not yet read
- [x] RunnerProxyConfig.swift — not yet read
- [x] RunnerProxyStoreError.swift — not yet read
- [x] RunnerProxyStoreProtocol.swift — not yet read
- [x] RunnerStatus.swift — ✅ clean; forward-compatible `.unknown` case correct
- [x] RunnerStatusEnricher.swift — ✅ clean (previous sessions)
- [x] RunnerStatusEnricherProtocol.swift — not yet read (protocol stub)
- [x] SaveRunnerEditsUseCase.swift — ✅ clean (previous sessions)
- [x] WorkflowActionGroup.swift — ✅ clean (previous sessions)
- [x] WorkflowActionGroupFetch.swift — ✅ clean (previous sessions)

### Sources/RunnerBarCore/Scope/
- [x] FailureHookRunnerDependencies.swift — ✅ clean; protocols correct
- [x] GitHubScope.swift — ✅ clean
- [x] ScopeEntry.swift — ✅ clean; `copying(isEnabled:)` pattern correct
- [x] ScopePreferencesStore.swift — ✅ clean (previous sessions)

### Sources/RunnerBarCore/Utilities/
- [x] AnyJSON.swift — ✅ clean
- [x] FormatElapsed.swift — ✅ clean
- [x] GitHubURLHelpers.swift — ✅ clean
- [x] ISO8601DateParser.swift — ✅ clean; actor isolation correct
- [x] Logger.swift — ✅ clean (previous sessions)
- [x] SystemStats.swift — not yet read

### Sources/RunnerBarCore/Services/
- [x] LogFetcher.swift — ⚠️ FINDING: free functions, no protocol, `FileManager` not injectable (see #1505)
- [x] ProcessRunner.swift — not yet read (21 KB — highest priority remaining)

### Sources/RunnerBar/App/
- [x] AppDelegate.swift — ⚠️ FINDING: `AnyView` type erasure in `wrapEnv`; IUO `runnerStore!`; over-documentation of NSPopover mechanics (see #1505)
- [x] AppDelegate+Navigation.swift — not yet read
- [x] AppDelegate+OAuthCallback.swift — not yet read
- [x] AppDelegate+PanelSetup.swift — not yet read (14 KB)
- [x] AppDelegate+Polling.swift — not yet read
- [x] AppDelegate+StatusItem.swift — not yet read
- [x] AppDelegate+StoreSetup.swift — not yet read
- [x] NavState.swift — not yet read
- [x] PanelSheetState.swift — not yet read
- [x] PanelVisibilityState.swift — not yet read
- [x] PopoverLifecycleCoordinator.swift — not yet read (12 KB)
- [x] main.swift — not yet read
- [x] Exports.swift — not yet read

### Sources/RunnerBar/DesignSystem/
- [x] DesignTokens.swift — ⚠️ FINDING: `RBStatus` duplicates `JobStatus`/`AggregateStatus` domain concepts (see #1505); otherwise strong adherence
- [x] PanelViewModifiers.swift — not yet read (14 KB)
- [x] RemovalAlertModifier.swift — not yet read

### Sources/RunnerBar/GitHub/
- [x] GitHubHelpers.swift — not yet read
- [x] GitHubTokenCache.swift — ⚠️ FINDING: `githubToken()` / `invalidateTokenCache()` are free functions, not injectable (see #1505)
- [x] OAuthSecrets.swift — ⚠️ FINDING: 40-line justification comment for a 2-line enum; comment belongs in a doc, not inline (see #1505)
- [x] OAuthService.swift — not yet read (15 KB)

### Sources/RunnerBar/Preferences/
- [x] AppPreferencesStore.swift — not yet read
- [x] NotificationPreferences.swift — not yet read

### Sources/RunnerBar/Runner/ (directory discovered this session)
- [x] CommitRunnerEdit.swift — not yet read (tiny)
- [x] LocalRunnerStore.swift — not yet read (21 KB — high priority)
- [x] PollLoopCoordinator.swift — not yet read (6 KB)
- [x] RunnerEditDraft.swift — not yet read
- [x] RunnerLifecycleService.swift — not yet read (15 KB — high priority)
- [x] RunnerProxyStore.swift — not yet read (9 KB)
- [x] RunnerStore+InstallPathMap.swift — not yet read
- [x] RunnerStore+PollBridge.swift — not yet read (8 KB)
- [x] RunnerStore+PollLoop.swift — not yet read
- [x] RunnerStore.swift — not yet read (31 KB — **highest priority**)

### Sources/RunnerBar/Scope/ (directory discovered this session)
- [x] ScopeEntry.swift (re-export) — not yet read (tiny)
- [x] ScopeStore.swift — not yet read (6 KB)

### Sources/RunnerBar/Services/ (directory discovered this session)
- [x] DefaultRunnerLabelsService.swift — not yet read
- [x] FailureHookRunner.swift — not yet read
- [x] FailureHookRunnerAdapters.swift — not yet read
- [x] Keychain.swift — not yet read (7 KB)
- [x] LoginItem.swift — not yet read
- [x] TerminalLauncher.swift — not yet read

### Sources/RunnerBar/UseCases/ (directory discovered this session)
- [x] FailureHookRunnerUseCase.swift — not yet read (16 KB — high priority)

### Sources/RunnerBar/Utilities/ (directory discovered this session)
- [x] WindowGrabber.swift — not yet read

### Sources/RunnerBar/Views/ (previous sessions)
- [x] ~20+ view files read in prior sessions

### Tests/RunnerBarCoreTests/ (previous sessions)
- [x] All test files read

---

## ❌ NOT YET READ

### Sources/RunnerBarCore/Runner/ (small protocol/model files)
- [ ] RunnerConfig.swift
- [ ] RunnerConfigStoreProtocol.swift
- [ ] RunnerEditDraft.swift
- [ ] RunnerLabelsServiceProtocol.swift
- [ ] RunnerModelParser.swift
- [ ] RunnerProxyConfig.swift
- [ ] RunnerProxyStoreError.swift
- [ ] RunnerProxyStoreProtocol.swift
- [ ] RunnerStatusEnricherProtocol.swift

### Sources/RunnerBarCore/Utilities/
- [ ] SystemStats.swift

### Sources/RunnerBarCore/Services/
- [ ] ProcessRunner.swift (21 KB)

### Sources/RunnerBar/App/
- [ ] AppDelegate+Navigation.swift
- [ ] AppDelegate+OAuthCallback.swift
- [ ] AppDelegate+PanelSetup.swift (14 KB)
- [ ] AppDelegate+Polling.swift
- [ ] AppDelegate+StatusItem.swift
- [ ] AppDelegate+StoreSetup.swift
- [ ] NavState.swift
- [ ] PanelSheetState.swift
- [ ] PanelVisibilityState.swift
- [ ] PopoverLifecycleCoordinator.swift (12 KB)
- [ ] main.swift
- [ ] Exports.swift

### Sources/RunnerBar/DesignSystem/
- [ ] PanelViewModifiers.swift (14 KB)
- [ ] RemovalAlertModifier.swift

### Sources/RunnerBar/GitHub/
- [ ] GitHubHelpers.swift
- [ ] OAuthService.swift (15 KB)

### Sources/RunnerBar/Preferences/
- [ ] AppPreferencesStore.swift
- [ ] NotificationPreferences.swift

### Sources/RunnerBar/Runner/
- [ ] CommitRunnerEdit.swift
- [ ] LocalRunnerStore.swift (21 KB)
- [ ] PollLoopCoordinator.swift (6 KB)
- [ ] RunnerEditDraft.swift
- [ ] RunnerLifecycleService.swift (15 KB)
- [ ] RunnerProxyStore.swift (9 KB)
- [ ] RunnerStore+InstallPathMap.swift
- [ ] RunnerStore+PollBridge.swift (8 KB)
- [ ] RunnerStore+PollLoop.swift
- [ ] **RunnerStore.swift (31 KB) — highest priority remaining**

### Sources/RunnerBar/Scope/
- [ ] ScopeEntry.swift (re-export)
- [ ] ScopeStore.swift (6 KB)

### Sources/RunnerBar/Services/
- [ ] DefaultRunnerLabelsService.swift
- [ ] FailureHookRunner.swift
- [ ] FailureHookRunnerAdapters.swift
- [ ] Keychain.swift (7 KB)
- [ ] LoginItem.swift
- [ ] TerminalLauncher.swift

### Sources/RunnerBar/UseCases/
- [ ] FailureHookRunnerUseCase.swift (16 KB)

### Sources/RunnerBar/Utilities/
- [ ] WindowGrabber.swift

### Tests/RunnerBarUITests/
- [ ] All files (never listed)

---

## FINDINGS LOG (all sessions)

All findings are ranked and tracked in issue [#1505](https://github.com/eoncode/runner-bar/issues/1505). This section is a raw log by file.

| File | Principle | Finding | Severity |
|------|-----------|---------|----------|
| `RunnerStore.swift` (prev sessions) | P — single responsibility | 30 KB god actor; too many concerns in one type | High |
| `AppDelegate.swift` | P — AnyView avoidance | `wrapEnv<V>` erases to `AnyView` on every navigation | High |
| `AppDelegate.swift` | P — avoid IUO | `var runnerStore: RunnerStore!` | Medium |
| `AppDelegate.swift` | Reach — lean code | NSPopover architecture comments duplicate ARCHITECTURE.md content | Low |
| `LogFetcher.swift` | Reach — testability | `fetchJobLog`, `fetchActionLogs`, `unzipLogs` are free functions; `FileManager` not injectable | Medium |
| `RunnerMetrics.swift` | Reach — testability | `metricsForRunner`, `allWorkerMetrics` are free async functions; no protocol | Medium |
| `GitHubTokenCache.swift` | Reach — testability | `githubToken()`, `invalidateTokenCache()` are free functions; not injectable | Medium |
| `OAuthSecrets.swift` | Reach — lean code | 40-line justification block for 2-line enum; explanation belongs in docs, not inline | Low |
| `DesignTokens.swift` | P — DRY | `RBStatus` duplicates status domain already expressed by `JobStatus`/`AggregateStatus` | Low |
| `WorkflowActionGroupFetch.swift` (prev sessions) | Reach — error handling | Network errors silently return empty arrays without surface to UI | Medium |
| `PollResultBuilder.swift` (prev sessions) | P — complexity | Deeply nested state machine logic; hard to test individual branches | Medium |
| Various view files (prev sessions) | P — view model fat | Some views construct logic inline rather than delegating to a view model | Low |
