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

---

## 5. `ObservationLoop.onChange` — mutating tracked properties inside `onChange`

**Status: addressed.** This is a real footgun but not a bug in the current callers.
The `onChange` parameter doc-comment in `ObservationLoop.init` now explicitly warns
that callers must not mutate `@Observable` properties that `observe` also reads —
because `onChange` fires before the next `register()` pass, such mutations occur before
tracking re-arms and will not trigger a subsequent cycle.

Current callers (`updateStatusIcon`) are pure side-effect sinks and are unaffected.

**Verify at:** `Sources/RunnerBarCore/Utilities/ObservationLoop.swift` —
`init(observe:onChange:)` `onChange` parameter doc-comment.

---

## 6. `fetchError: Error?` — missing `& Sendable` constraint

**Claim:** `RunnerState.fetchError` is typed `Error?` rather than
`(any Error & Sendable)?` — unsafe for cross-actor use under Swift 6 strict concurrency.

**Reality:** `fetchError` is `internal`, completely unwired, and has an inline TODO
that explicitly calls for the `& Sendable` constraint at wiring time. Applying the
constraint now would add noise to dead scaffolding and constitutes a public API change
before the semantics are settled. The constraint will be applied atomically when
`applyFetchResult` is wired to write it. No action required on this PR.

**Verify at:** `Sources/RunnerBarCore/Runner/RunnerState.swift` —
`fetchError` property and its inline TODO comment.

---

## 7. `extraOrgScopes.contains` — O(n) array lookup

**Claim:** `fetchAndEnrichRunners` Phase 0 uses `extraOrgScopes.contains(orgScope)` on
an `Array` inside a loop — O(n²) in the worst case; should use a `Set`.

**Reality:** The outer loop iterates `localRunners` — runners physically installed on
the local machine. In any realistic fleet this is a single-digit to low-tens count.
`extraOrgScopes` is a subset of that. There is no plausible input size where the
array lookup matters. Converting to `Set` would also silently drop the insertion-order
semantics that the current code provides implicitly (scopes are fetched in the order
they are discovered, which matches the original `RunnerStore` behaviour). No action.

**Verify at:** `Sources/RunnerBarCore/Runner/RunnerPoller.swift` —
`fetchAndEnrichRunners`, Phase 0 block.
