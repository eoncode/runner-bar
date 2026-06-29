# Data Model

This document describes the runtime data model of RunBot: how the GitHub poll loop
fetches and enriches state, how that state reaches SwiftUI, and how local (on-disk)
runners are reconciled with GitHub-hosted runners.

> **Note on naming history.** What this document previously called `RunnerStore` was
> renamed to **`RunnerPoller`** and moved into the `RunBotCore` target ("Step 10").
> The old `RunnerViewModel` push-coupling has been replaced by an injected
> **`RunnerState`** observable read model ("Step 14"). The sections below reflect the
> current code.

---

## `RunnerPoller` — what it does today

`RunnerPoller` is a Swift 6 `actor` in `RunBotCore` that owns the GitHub poll loop
and all derived runner/job/action state. It runs on its own (background) executor and
has **no import of the `RunBot` app target** — all app-layer dependencies are injected
as protocol-typed values or closures.

**1. Polls GitHub on a timer**
A structured `Task` loop fetches immediately, sleeps `nextPollInterval()` seconds, then
repeats until cancelled. The interval is **10s when jobs are actively running**, otherwise
the user's configured idle interval (`preferencesStore.pollingInterval`, floored at 10s).
While rate-limited it also falls back to the idle interval.

**2. Fetches and enriches runners**
For each active scope (org or repo slug) it fetches the GitHub runner list across two
concurrent `withTaskGroup` phases (the `IndexedScopedRunner` carrier keeps a fetched
`Runner` paired with its source scope). For busy runners it resolves the local install
path via an `InstallPathMap` and reads live CPU/memory metrics from the machine.

**3. Maintains job and action-group state**
It tracks live jobs, a capped completed-job cache, live workflow action groups, and a
group cache — comparing each poll result against the previous snapshot to detect
vanished jobs/groups and fire failure hooks.

**4. Handles rate limiting**
It keeps an actor-local `isRateLimited` / `rateLimitResetDate` copy (read by
`nextPollInterval()`) and mirrors it into `RunnerState`. On a failed cycle it still syncs
these so a rate-limited failure doesn't leave stale interval behaviour.

**5. Pushes results to `RunnerState` on the main actor**
After every cycle, `applyFetchResult` does `await MainActor.run { state.runners = …;
state.jobs = …; state.actions = … }`. SwiftUI's `@Observable` machinery picks up the
mutation automatically — **no Combine `PassthroughSubject` and no `RunnerViewModel`
coupling**. Status-icon refresh is no longer triggered from inside the actor; `AppDelegate`
wires an `ObservationLoop` on `state.runners` instead.

### `PollLoopCoordinator`

`RunnerPoller` owns a `PollLoopCoordinator` (`private let pollLoop`) that holds the three
`Task` handles driving the loop: the poll task, the interval-observation task, and the
scope-observation task. Because it's a stored property of the actor, all access is
serialised by the actor's executor. It carries a documented `@unchecked Sendable`
sign-off (a deliberate Principle #4 exception) so `deinit` can cancel the handles.

### `RunnerPollerProtocol` and `MockPoller`

`AppDelegate` types the poller as `any RunnerPollerProtocol` (`func start() async` +
`var state: RunnerState { get }`). `RunnerPoller` is the production conformer; `MockPoller`
is a no-op actor for SwiftUI previews and snapshot tests — `start()` is a guaranteed no-op
that never touches the network.

---

## `RunnerState` — the observable read model

`RunnerState` is an `@Observable @MainActor public final class` populated by `RunnerPoller`
and consumed read-only by views and `AppDelegate` (via `withObservationTracking` /
`ObservationLoop`). It replaces the old `RunnerViewModel` push target.

Poll-written properties are `public internal(set)` — only `RunnerPoller.applyFetchResult`
(same module) mutates them:

- `runners: [Runner]` — enriched GitHub runner snapshots
- `jobs: [ActiveJob]` — live + recently-completed jobs
- `actions: [WorkflowActionGroup]` — workflow run groups
- `isRateLimited: Bool`
- `rateLimitResetDate: Date?`
- `fetchError: (any Error)?`

Two properties are `public var` (only `LocalRunnerStore` writes them in practice; the
`public` setter is required to satisfy the `RunnerViewModelProtocol` `{ get set }`
requirement):

- `localRunners: [RunnerModel]`
- `isLocalScanning: Bool`

It also exposes a derived `aggregateStatus: AggregateStatus` computed property.

---

## `RunnerModel` — local (on-disk) runner

`RunnerModel` is a **local self-hosted runner** discovered by scanning LaunchAgent plists
in `~/Library/LaunchAgents`, managed by the `LocalRunnerStore` actor. After discovery,
`RunnerStatusEnricher` enriches each model with live GitHub API data (`githubStatus`,
`isBusy`, `labels`, `runnerGroup`).

It is **fully `Sendable`**: all properties are `let`, and mutations go through a
`copying(…)` method that returns a new value — no in-place mutation, so the compiler
synthesises `Sendable` without an `@unchecked` escape hatch. Key fields:

- Identity / location: `id`, `runnerName`, `installPath`, `gitHubUrl`, `agentId`, `apiId`, `workFolder`
- Config: `labels`, `platform`, `platformArchitecture`, `agentVersion`, `isEphemeral`, `runnerGroup`
- Live state: `isRunning` (from `launchctl`), `githubStatus`, `isBusy`, `lifecycleWarning`, `metrics`
- Derived: `displayStatus`, `statusColor`

`RunnerModel` is the local ground truth used to build the `InstallPathMap` that resolves
which local machine runner corresponds to which GitHub API runner.

---

## `Runner` — GitHub API runner snapshot

`Runner` is the API-decoded remote snapshot (API-first, vs. `RunnerModel` which is
local-first): `id: Int`, `name`, `status: RunnerStatus`, `busy: Bool`, optional
`metrics: RunnerMetrics`, plus a derived `displayStatus`. `RunnerPoller` enriches busy
`Runner`s with metrics read from the corresponding local runner.

---

## How they relate

```
LocalRunnerStore (actor, Core)
  └─ [RunnerModel]              ← "what's installed on this Mac" (LaunchAgent scan)
        │  installPathMap
        ▼
RunnerPoller (actor, Core)
  ├─ fetchAndEnrichRunners()    ← GitHub API → [Runner]  (two withTaskGroup phases)
  ├─ enriches busy runners      ← reads CPU/MEM metrics from disk
  ├─ tracks jobs + action groups, fires failure hooks on vanished items
  ├─ handles rate limiting      ← actor-local copy + mirrored to state
  └─ applyFetchResult()         ← await MainActor.run { state.runners/jobs/actions = … }
        │
        ▼
RunnerState (@Observable @MainActor, Core)   ← read-only model
        │
        ▼
SwiftUI views + AppDelegate (ObservationLoop on state.runners)
```

`RunnerModel` is the local ground truth; `Runner` is the GitHub API model.
`RunnerPoller` reconciles the two every poll tick and writes the merged result into
`RunnerState`, which SwiftUI observes directly — no push coupling, no app-target import
from Core.
