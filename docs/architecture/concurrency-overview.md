## Architecture Overview

The concurrency model is explicit and compiler-enforced end-to-end . All UI state lives on `@MainActor`, all background domain work is isolated in dedicated actors, and there are no `@unchecked Sendable` escape hatches in production types . The system maps to **six core concurrency pillars** across 21 documented principles.

***

## Pillar 1: Actor-Per-Concern Isolation (P1, P16)

Each mutable domain owns its own actor — there is no single "background actor" everything piles into . The canonical examples are:
- **`RateLimitActor`** — serialises all rate-limit state and exposes a `snapshot()` method for atomic reads (P10)
- **`RunnerConfigStore`** — its own actor, serialising all disk I/O for `.runner` config files
- **`LocalRunnerStore`** — pushes snapshots to `viewModel.localRunners` on `MainActor` using `await MainActor.run` (not fire-and-forget `Task`) to guarantee mutation ordering 

## Pillar 2: MainActor Boundary Crossings (P2)

Views and ViewModels are `@MainActor`-isolated . The boundary-crossing pattern used throughout is:

```swift
let scopes = await MainActor.run { scopeStore.activeScopes }
```

This is used in `RunnerStore.start()` and `RunnerStore+PollBridge` to safely read `@MainActor`-isolated properties from a background context . `Task { @MainActor in ... }` is used for fire-and-forget operations from SwiftUI views (e.g. `SettingsView`, `ScopesView`, `StepLogView`) .

## Pillar 3: Structured Concurrency for Timers & Loops (P9)

All timers use `Task` + `Task.sleep(for:)` rather than `DispatchQueue.asyncAfter` . A **generation counter** guards against stale-task races where a sleeping task wakes after a newer window has started . `PanelContainerView` uses a named poll task:

```swift
pollTask = Task(name: "sheetPoll") { @MainActor in
    while !Task.isCancelled {
        try await Task.sleep(for: .milliseconds(100))
    }
}
```

Task names leverage Swift 6.2's `Task(name:)` API (SE-0462) for Instruments/crash log debuggability .

## Pillar 4: Atomic Snapshot Pattern (P10)

Related values are never fetched with two separate `await` calls across an actor boundary . The `RateLimitActor.snapshot()` method returns `isLimited` and `resetDate` atomically in one hop — the canonical TOCTOU-eliminating pattern in the codebase . Parallel fetches use `async let` binding:

```swift
async let fetchedOrgs = fetchUserOrgs()
async let fetchedRepos = fetchUserRepos()
let (resolvedOrgs, resolvedRepos) = await (fetchedOrgs, fetchedRepos)
```

This is visible in `AddScopeSheet.swift` .

## Pillar 5: `@concurrent` for Blocking I/O (P18)

Synchronous disk I/O is placed in `@concurrent` async free functions, keeping blocking calls off actor serial executors . `LogFetcher` is a `Sendable` struct whose entry points are `async` but not `@concurrent` — they are called from `Task.detached` contexts (not actor-isolated paths) . `ProcessRunner` retains the legacy `withCheckedContinuation` + `DispatchQueue` bridge because it requires a deliberate `DispatchQueue.sync` barrier as a join point; this pattern is not to be introduced in new code .

## Pillar 6: Sendable Use-Cases & Non-Isolated Structs (P8, P17)

Business logic lives in `Sendable` use-case structs (e.g. `WorkflowActionsUseCase`, `FailureHookRunnerUseCase`) with no isolation annotation . Because they are non-actor `Sendable` structs, all methods run on the cooperative thread pool when called with `await` from inside a `Task {}` (P18) . `JSONDecoder` instances are `nonisolated` on actors where captured inside closures, expressing that they have no mutable state post-init — not as a workaround, but as a precise compiler-checked immutability guarantee (P17) .

***

## Concurrency Ownership Map

| Component | Isolation | Pattern |
|---|---|---|
| `RunnerStore` / `RunnerStore+PollBridge` | nonisolated / background Task | `withTaskGroup`, `await MainActor.run` |
| `LocalRunnerStore` | background actor | `await MainActor.run` for UI pushes (ordered) |
| `RunnerConfigStore` | actor | `@concurrent` disk I/O helpers |
| `RateLimitActor` | actor | `snapshot()` atomic reads (P10) |
| `GitHubRateLimitHandler` | actor | generation counter for stale-task guard |
| `FailureHookRunnerUseCase` | Sendable struct | inline `async`, no `Task.detached` |
| `LogFetcher` | Sendable struct | `async` entry points, `Task.detached` callers |
| All SwiftUI Views | `@MainActor` | Plain `Task {}` inherits isolation |
| `ProcessRunner` | nonisolated | Legacy `withCheckedContinuation` + `DispatchQueue` (deliberate) |

The principles document (P4) confirms this is a **build-time guarantee** — no `@unchecked Sendable` in production, every actor crossing visible at the call site .