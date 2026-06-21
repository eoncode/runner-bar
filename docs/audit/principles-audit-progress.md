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
- [x] GitHubRateLimitHandler.swift — ✅ clean (finding #18 already in issue: module-level singleton)
- [x] GitHubRequestBuilder.swift — ✅ clean
- [x] GitHubResponseDecoder.swift — ✅ clean
- [x] GitHubTransportShim.swift — ✅ clean (previous sessions)
- [x] GitHubURLSessionTransport.swift — ⚠️ FINDING #11 in issue: all transport as free module-level functions

### Sources/RunnerBarCore/Runner/
- [x] ActiveJob.swift — ⚠️ FINDING #15 in issue: 12-param init with NOSONAR suppression
- [x] AggregateStatus.swift — ✅ clean
- [x] CommitResult.swift — ✅ tiny value type, no violations
- [x] JobStatus.swift — ⚠️ FINDING #16 in issue: manual rawValue + Codable + init(rawString:) triplication
- [x] LocalRunnerIndex.swift — ✅ clean, injectable via init
- [x] PollResultBuilder.swift — ⚠️ FINDING #14 in issue: Set eviction not FIFO
- [x] PollResults.swift — ✅ clean
- [x] Runner.swift — ✅ clean; `copying(metrics:)` pattern correct
- [x] RunnerConfig.swift — ✅ small value type, no violations
- [x] RunnerConfigStore.swift — ✅ clean (previous sessions)
- [x] RunnerConfigStoreProtocol.swift — ✅ protocol stub, no violations
- [x] RunnerEditDraft.swift (Core) — ✅ clean builder pattern
- [x] RunnerLabelsServiceProtocol.swift — ✅ protocol stub, no violations
- [x] RunnerMetrics.swift — ⚠️ FINDING (session 2): free async functions, not injectable (see #1505)
- [x] RunnerModel.swift — ⚠️ FINDING #10 in issue: 18-param init with NOSONAR suppression
- [x] RunnerModelParser.swift — ✅ clean; free functions but pure/stateless, no DI needed
- [x] RunnerProxyConfig.swift — ✅ small value type, no violations
- [x] RunnerProxyStoreError.swift — ✅ error enum, no violations
- [x] RunnerProxyStoreProtocol.swift — ✅ protocol stub, no violations
- [x] RunnerStatus.swift — ✅ clean; forward-compatible `.unknown` case correct
- [x] RunnerStatusEnricher.swift — ⚠️ FINDING #13 in issue: `static let shared` singleton bypasses DI
- [x] RunnerStatusEnricherProtocol.swift — ✅ protocol stub, no violations
- [x] SaveRunnerEditsUseCase.swift — ✅ clean (previous sessions)
- [x] WorkflowActionGroup.swift — ⚠️ FINDINGS #12, #17 in issue: Equatable skips fields; silent .completed fallthrough
- [x] WorkflowActionGroupFetch.swift — ⚠️ FINDING #6 in issue: file-scoped shared JSONDecoder

### Sources/RunnerBarCore/Scope/
- [x] FailureHookRunnerDependencies.swift — ✅ clean; protocols correct
- [x] GitHubScope.swift — ✅ clean
- [x] ScopeEntry.swift — ✅ clean; `copying(isEnabled:)` pattern correct
- [x] ScopePreferencesStore.swift — ⚠️ FINDINGS #1, #3 in issue: raw UserDefaults; no actor isolation

### Sources/RunnerBarCore/Utilities/
- [x] AnyJSON.swift — ✅ clean
- [x] FormatElapsed.swift — ✅ clean
- [x] GitHubURLHelpers.swift — ✅ clean
- [x] ISO8601DateParser.swift — ✅ clean; actor isolation correct
- [x] Logger.swift — ⚠️ FINDING #8 in issue: single "general" category across all subsystems
- [x] SystemStats.swift — ✅ clean; actor-isolated sampling, no violations

### Sources/RunnerBarCore/Services/
- [x] LogFetcher.swift — ⚠️ FINDING (session 2): free functions, no protocol, FileManager not injectable
- [x] ProcessRunner.swift — ⚠️ FINDING #4 in issue: last `DispatchQueue.sync` in production path (intentional, documented sign-off in file)

### Sources/RunnerBar/App/
- [x] AppDelegate.swift — ⚠️ FINDINGS: `AnyView` type erasure in `wrapEnv`; IUO `runnerStore!`; over-documentation of NSPopover mechanics
- [x] AppDelegate+Navigation.swift — ✅ clean; focused navigation state helpers
- [x] AppDelegate+OAuthCallback.swift — ✅ clean; thin delegate bridge
- [x] AppDelegate+PanelSetup.swift — ⚠️ **NEW FINDING #21**: `RunnerStore` constructed **three times** in `setupSubscriptions()` — three consecutive identical `runnerStore = RunnerStore(...)` assignments; first two instances are silently discarded; `DispatchQueue.main.async` in KVO callback (Principle 2 — GCD remnant)
- [x] AppDelegate+Polling.swift — ✅ clean; thin poll-trigger bridge
- [x] AppDelegate+StatusItem.swift — ✅ clean; status-bar icon helpers
- [x] AppDelegate+StoreSetup.swift — ✅ clean; store wiring
- [x] NavState.swift — ✅ clean; simple enum
- [x] PanelSheetState.swift — ✅ clean; simple enum
- [x] PanelVisibilityState.swift — ✅ clean; well-structured open/close/hide logic
- [x] PopoverLifecycleCoordinator.swift — ✅ clean; well-extracted coordinator
- [x] main.swift — ✅ clean; entry point only
- [x] Exports.swift — ✅ clean; re-exports only

### Sources/RunnerBar/DesignSystem/
- [x] DesignTokens.swift — ⚠️ FINDING (session 2): `RBStatus` duplicates `JobStatus`/`AggregateStatus` domain concepts
- [x] PanelViewModifiers.swift — ✅ clean; focused view modifiers
- [x] RemovalAlertModifier.swift — ✅ clean; single-responsibility modifier

### Sources/RunnerBar/GitHub/
- [x] GitHubHelpers.swift — ✅ clean; pure free functions, no state
- [x] GitHubTokenCache.swift — ⚠️ FINDING (session 2): `githubToken()` / `invalidateTokenCache()` are free functions, not injectable
- [x] OAuthSecrets.swift — ⚠️ FINDING (session 2): 40-line justification comment for a 2-line enum
- [x] OAuthService.swift — ⚠️ **NEW FINDING #22**: `static let shared` singleton with no DI protocol; `NSWorkspace.shared.open(url)` called directly inside the class (Principle 7 — singleton bypasses DI; Principle 4 — direct singleton access inside service)

### Sources/RunnerBar/Preferences/
- [x] AppPreferencesStore.swift — ⚠️ FINDING #2 in issue: raw `UserDefaults.standard` string keys, not `Codable` (confirmed)
- [x] NotificationPreferences.swift — ✅ clean; same UserDefaults pattern but scoped and intentional

### Sources/RunnerBar/Runner/
- [x] CommitRunnerEdit.swift — ✅ clean; tiny use-case
- [x] LocalRunnerStore.swift — ✅ clean; well-structured actor with proper DI; `enricher` injected via protocol
- [x] PollLoopCoordinator.swift — ✅ clean; `@unchecked Sendable` with full documented principle sign-off in file
- [x] RunnerEditDraft.swift — ✅ clean builder pattern
- [x] RunnerLifecycleService.swift — ⚠️ **NEW FINDING #23**: `static let shared` singleton with no DI protocol; `FileManager.default` called directly throughout (Principle 7 — singleton; Principle 4 — direct singleton access)
- [x] RunnerProxyStore.swift — ✅ clean; actor-isolated, injectable
- [x] RunnerStore+InstallPathMap.swift — ✅ clean; pure function, no state
- [x] RunnerStore+PollBridge.swift — ⚠️ FINDING #19 in issue: `buildJobState` and `buildGroupState` call `ScopeStore.shared.scopes` directly, bypassing the injected `scopeStore` (confirmed)
- [x] RunnerStore+PollLoop.swift — ✅ clean; migration boundary comment only
- [x] RunnerStore.swift — ✅ clean; well-structured actor with proper DI throughout

### Sources/RunnerBar/Scope/
- [x] ScopeEntry.swift (re-export) — ✅ clean
- [x] ScopeStore.swift — ⚠️ **NEW FINDING #24**: `var scopes: [String]` legacy accessor is documented as "not yet migrated" and kept on the public surface — dead API violating Principle 6 (no stale public API); all live call sites should use `activeScopes`

### Sources/RunnerBar/Services/
- [x] DefaultRunnerLabelsService.swift — ✅ clean; implements protocol correctly
- [x] FailureHookRunner.swift — ✅ clean; thin production shim, delegates to use-case
- [x] FailureHookRunnerAdapters.swift — ✅ clean; protocol adapters
- [x] Keychain.swift — ⚠️ FINDING #9 in issue: non-atomic SecItem mutation + cache invalidation (FIXME(P24) confirmed in file)
- [x] LoginItem.swift — ✅ clean; focused launch-item helper
- [x] TerminalLauncher.swift — ✅ clean; protocol + adapter pattern correct

### Sources/RunnerBar/UseCases/
- [x] FailureHookRunnerUseCase.swift — ⚠️ FINDING #5 in issue: `Task.detached` fire-and-forget (confirmed; intentional for MainActor isolation break — documented in file)

### Sources/RunnerBar/Utilities/
- [x] WindowGrabber.swift — ✅ clean; focused NSWindow helper

### Sources/RunnerBar/Views/ (previous sessions)
- [x] ~20+ view files read in prior sessions — findings previously logged

### Tests/RunnerBarCoreTests/ (previous sessions)
- [x] All test files read

---

## ❌ NOT YET READ

### Tests/RunnerBarUITests/
- [ ] All files (never listed or read)

---

## FINDINGS LOG (all sessions)

All findings are ranked and tracked in issue [#1505](https://github.com/eoncode/runner-bar/issues/1505). This section is a raw log by file.

| # | File | Principle | Finding | Severity |
|---|------|-----------|---------|----------|
| 1 | `ScopePreferencesStore.swift` | P3 | Raw `UserDefaults` string keys instead of `Codable` | High |
| 2 | `AppPreferencesStore.swift` | P3 | Raw `UserDefaults` string keys instead of `Codable` | High |
| 3 | `ScopePreferencesStore.swift` | P7 + P16 | Static methods only, no actor isolation | High |
| 4 | `ProcessRunner.swift` | P2 + P9 | Last `DispatchQueue.sync` in production path (intentional, documented sign-off) | Medium |
| 5 | `FailureHookRunnerUseCase.swift` | P9 | `Task.detached` fire-and-forget (documented intent) | Medium |
| 6 | `WorkflowActionGroupFetch.swift` | P4 + P17 | File-scoped shared `JSONDecoder` across concurrent calls | Medium |
| 7 | `AppDelegate.swift` | P8 | Business logic leaking into app layer | High |
| 8 | `Logger.swift` | P15 + P16 | Single `"general"` category across all subsystems | Low |
| 9 | `Keychain.swift` | P10 | Non-atomic SecItem mutation + cache invalidation (FIXME(P24) in file) | Medium |
| 10 | `RunnerModel.swift` | P6 + P8 | 18-param init with `// NOSONAR` suppression | Medium |
| 11 | `GitHubURLSessionTransport.swift` | P7 + P16 | All transport as free module-level functions; two module-level globals | High |
| 12 | `WorkflowActionGroup.swift` | P6 | `Equatable` skips all fields except `id` | Medium |
| 13 | `RunnerStatusEnricher.swift` | P7 | `static let shared` singleton bypasses DI | Medium |
| 14 | `PollResultBuilder.swift` | P5 | `Set` eviction is arbitrary, not FIFO — can re-fire failure hook | Medium |
| 15 | `ActiveJob.swift` | P6 + P8 | 12-param init with `// NOSONAR` suppression | Medium |
| 16 | `JobStatus.swift` | P6 | Manual `rawValue` + `Codable` + `init(rawString:)` triplication; `ExpressibleByStringLiteral` on public API | Medium |
| 17 | `WorkflowActionGroup.swift` | P8 | Silent `.completed` fallthrough for loading state; `// TODO: revisit` unresolved | Medium |
| 18 | `GitHubRateLimitHandler.swift` | P7 + P16 | Module-level singleton `rateLimitActor` bypasses full DI | Medium |
| 19 | `RunnerStore+PollBridge.swift` | P4 + P7 | `buildJobState`/`buildGroupState` call `ScopeStore.shared.scopes` directly, bypassing injected `scopeStore` | High |
| 20 | `AppDelegate+PanelSetup.swift` (prev) | P8 + P16 | `RunnerStore` constructed 3× in `setupSubscriptions()` — first 2 instances silently discarded | High |
| 21 | `AppDelegate+PanelSetup.swift` | P2 | `DispatchQueue.main.async` in KVO callback instead of `Task { @MainActor }` | Low |
| 22 | `OAuthService.swift` | P7 + P4 | `static let shared` singleton with no DI protocol; `NSWorkspace.shared.open` called directly inside service | Medium |
| 23 | `RunnerLifecycleService.swift` | P7 + P4 | `static let shared` singleton with no DI protocol; `FileManager.default` called directly throughout | Medium |
| 24 | `ScopeStore.swift` | P6 | `var scopes: [String]` legacy accessor documented as "not yet migrated" — dead public API | Low |
| S2a | `LogFetcher.swift` | Reach — testability | `fetchJobLog`, `fetchActionLogs`, `unzipLogs` are free functions; `FileManager` not injectable | Medium |
| S2b | `RunnerMetrics.swift` | Reach — testability | `metricsForRunner`, `allWorkerMetrics` are free async functions; no protocol | Medium |
| S2c | `GitHubTokenCache.swift` | Reach — testability | `githubToken()`, `invalidateTokenCache()` are free functions; not injectable | Medium |
| S2d | `OAuthSecrets.swift` | Reach — lean code | 40-line justification block for 2-line enum; explanation belongs in docs, not inline | Low |
| S2e | `DesignTokens.swift` | P — DRY | `RBStatus` duplicates status domain already expressed by `JobStatus`/`AggregateStatus` | Low |
