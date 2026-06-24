# PR #1566 — Common false-positive review findings

This file documents findings that look correct in the diff but are **not bugs**.
Before filing a finding on this PR, check the list below and verify against the
**branch files**, not the diff.

---

## 1. `PreferencesObserver` stream type mismatch

**Claim:** `PreferencesObserver` holds an `AsyncStream<Int>.Continuation` but
`RunnerPoller.startObservingPreferences` creates `AsyncStream<TimeInterval>.makeStream()`
— type mismatch, will not compile.

**Reality:** `PreferencesObserver.continuation` is typed
`AsyncStream<TimeInterval>.Continuation`. The `Int → TimeInterval` conversion happens
inside `start()` at the `yield` call site:

```swift
self.continuation.yield(TimeInterval(self.store.pollingInterval))
```

The stream types are consistent end-to-end. The old `RunnerStore` used `AsyncStream<Int>`
throughout; this was intentionally changed so the yielded value can be passed directly to
`nextPollInterval()` without a second conversion at the consumer.

**Verify at:** `Sources/RunnerBarCore/Runner/RunnerPollerObservers.swift` —
`PreferencesObserver.continuation` property and `start()` body.

---

## 2. `fetchAndEnrichRunners` Phase 0 — org-scope derivation missing

**Claim:** The `var extraOrgScopes` block from the original `RunnerStore` is absent
from `RunnerPoller.fetchAndEnrichRunners` — silent regression for org runners not in
`activeScopes`.

**Reality:** Phase 0 is present and unchanged. It lives at the top of
`fetchAndEnrichRunners`, clearly marked `// MARK: Phase 0 — Extra org-scope derivation`.
Reviewers who diff the file see the function body start in the middle of the move and
miss the block above it.

**Verify at:** `Sources/RunnerBarCore/Runner/RunnerPoller.swift` —
`fetchAndEnrichRunners`, first block after the `log("ENTER")` call.

---

## 3. `statusIconLoop` wired after `setupPanel()` — first poll result missed

**Claim:** `statusIconLoop` is assigned after `setupPanel()` in
`applicationDidFinishLaunching`. If `applyFetchResult` writes to `runnerState` before
the assignment, the first status-icon update is missed.

**Reality:** `setupPanel → setupSubscriptions` spawns an **inner** `Task` that suspends
on `await localRunnerStore.refreshAsync()` before calling `store.start()`. The suspension
yields back to the `@MainActor` queue, so the outer `Task {}` continues to the
`statusIconLoop = ObservationLoop { … }` assignment **before** `start()` is ever called.
There is no reachable path where `applyFetchResult` fires before `statusIconLoop` is
registered.

**Verify at:** `Sources/RunnerBar/App/AppDelegate+StoreSetup.swift` —
`applicationDidFinishLaunching` doc-comment ("statusIconLoop ordering" section) and
`Sources/RunnerBar/App/AppDelegate+PanelSetup.swift` —
`setupSubscriptions`, the `Task(name: "AppDelegate.startup: …")` block.

---

## 4. `self.decoder` inside `withTaskGroup` serialises concurrent fetches

**Claim:** Each `withTaskGroup` child task accesses `self.decoder`, forcing a hop back
onto the actor's serial executor per task and defeating the concurrent fan-out intent.

**Reality:** `decoder` is a `let` constant on the actor. Accessing a `let` property
inside a child task does not serialise the tasks — there is no mutable state to protect.
`JSONDecoder` is `@unchecked Sendable` and stateless after initialisation. The child
tasks run concurrently. A local `let d = self.decoder` capture would be equivalent
but is not required for correctness or performance.

**Verify at:** `Sources/RunnerBarCore/Runner/RunnerPoller.swift` —
`decoder` property doc-comment.
