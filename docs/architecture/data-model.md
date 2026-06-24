## `RunnerStore` — what it does today

It's a Swift 6 `actor` that owns **everything data-related** in the app.  Concretely:

**1. Polls GitHub on a timer**
It runs a structured `Task` poll loop — fetch immediately, sleep for N seconds, fetch again, repeat forever. The interval is 10s when jobs are actively running, otherwise the user's configured idle interval (min 10s). 

**2. Fetches and enriches runners**
For each active scope (org or repo slug), it fetches the list of GitHub-hosted runners, then for any *busy* runner it looks up the local install path and reads live CPU/memory metrics from the machine. 

**3. Maintains job and action group state**
It tracks live jobs, a completed-job cache (capped size), live workflow action groups, and a group cache — comparing each poll result against the previous snapshot to detect vanished jobs/groups and fire failure hooks. 

**4. Handles rate limiting**
Detects GitHub API rate limit responses, sets `isRateLimited`, widens the poll interval automatically, and records the reset date. 

**5. Pushes everything to `RunnerViewModel`**
After every fetch cycle, it calls `await MainActor.run { viewModel.runners = ...; viewModel.jobs = ...; viewModel.actions = ... }` — this is the coupling that blocks it from moving to Core. 

***

## `RunnerModel` — what it does today

`RunnerModel` is a **local runner** — a runner installed on this machine (not a GitHub-hosted cloud runner). It's the `@Observable` model object that `LocalRunnerStore` manages. It holds:

- The runner's name, install path, agent ID, API ID, GitHub URL
- Live CPU/memory metrics (written back by `RunnerStore` after each poll)
- Status from `launchctl` (running/stopped/error)

It's the bridge between what GitHub knows about a runner and what's physically on disk — `RunnerStore` uses it to build the `InstallPathMap` that resolves which local machine runner corresponds to which GitHub API runner ID. 

***

## How they relate

```
LocalRunnerStore (actor)
  └─ [RunnerModel]           ← "what's installed on this Mac"
        ↓ installPathMap
RunnerStore (actor)
  ├─ fetchRunners(scope:)    ← GitHub API → [Runner]
  ├─ enriches busy runners   ← reads metrics from disk
  ├─ writes metrics back     ← localRunnerStore.applyMetrics(...)
  └─ pushes to RunnerViewModel ← the coupling we'd break
```

`RunnerModel` is the local ground truth. `Runner` (from Core) is the GitHub API model. `RunnerStore` reconciles the two every poll tick and hands the merged result to SwiftUI via `RunnerViewModel`.

Sources
