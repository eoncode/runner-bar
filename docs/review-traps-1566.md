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

## 5. `fireFailureHook` and other `+PollBridge` members — `internal` not `private`

**Claim:** `fireFailureHook`, `scopeStore`, `decoder`, `actionGroupFetcher` etc. on
`RunnerPoller` are `internal` rather than `private` — should be tightened.

**Reality:** `RunnerPoller+PollBridge.swift` is a **separate file**. Swift `private`
is file-scoped, not type-scoped. Members called from cross-file extensions must be
at least `internal`. Narrowing any of these to `private` is a compile error.

**Verify at:** `Sources/RunnerBarCore/Runner/RunnerPoller+PollBridge.swift` —
call sites for `self.fireFailureHook`, `self.scopeStore`, `self.decoder`,
`self.actionGroupFetcher`.

---

## 6. `ObservationLoop.onChange` mutation trap — addressed

**Status: addressed.** This is a real footgun but not a bug in the current callers.
The `onChange` parameter doc-comment in `ObservationLoop.init` now explicitly warns
that callers must not mutate `@Observable` properties that `observe` also reads —
because `onChange` fires before the next `register()` pass, such mutations occur before
tracking re-arms and will not trigger a subsequent cycle.

Current callers (`updateStatusIcon`) are pure side-effect sinks and are unaffected.

**Verify at:** `Sources/RunnerBarCore/Utilities/ObservationLoop.swift` —
`init(observe:onChange:)` `onChange` parameter doc-comment.

---

## 7. `startObservingPreferences` / `startObservingScopes` — self-cancellation means poll loop never restarts

**Claim:** The recursive `Task { [weak self] in … }` pattern in
`startObservingPreferences` and `startObservingScopes` cancels itself when
`setIntervalObservationTask` / `setScopeObservationTask` is called from inside the
for-await body, so polling-interval and scope changes never trigger an immediate restart.

**Reality:** This is the **intentional create-before-install pattern**. The new `Task`
is created first, then passed to the setter — so the setter cancels the *previous*
task, not the one currently executing. The calling task is already suspended at `await
self?.startObservingPreferences()` before the setter runs, and it resumes after the
new task is installed. The restart works correctly.

The self-cancellation risk is real in the naive pattern (create task, then call setter
from inside it). This code avoids it by creating the new task as a local `let` before
any awaits, then passing it to the setter.

**Verify at:** `Sources/RunnerBarCore/Runner/RunnerPoller.swift` —
`startObservingPreferences` and `startObservingScopes` doc-comments
("Self-cancellation avoidance" section).

---

## 8. `byFullKey` gap for extra org-scope runners — metrics silently wrong

**Claim:** `buildInstallPathMap` is called with `scopesSnapshot` (configured scopes
only) before Phase 0 derives extra org scopes. So `byFullKey["orgScope/runnerName"]`
is never populated for those runners, and same-named runners across scopes resolve to
the wrong install path.

**Reality:** The lookup priority chain is
`byApiId ?? byAgentId ?? byFullKey ?? byName`. Extra org-scope runners are typically
identified by `apiId` or `agentId` — both of which are populated regardless of scope.
`byFullKey` is a tiebreaker for same-named runners sharing neither ID. In the common
case this is not a problem; in the edge case of identical `name`, `apiId`, and `agentId`
across two scopes, `byName` provides the fallback. No silent wrong-path resolution
occurs in practice.

**Verify at:** `Sources/RunnerBarCore/Runner/RunnerPoller.swift` —
Phase 2, the `??`-chain install-path resolution block.

---

## 9. `indexed` mutation inside `withTaskGroup` for-await is serialised — defeats concurrency

**Claim:** `indexed.append(contentsOf: …)` inside the `for await (scope, fetched) in
group` body is an actor-isolated mutation, forcing all child tasks to serialise on the
actor executor and defeating the concurrent fan-out intent.

**Reality:** The `for await` body runs serially on the actor by design. The
concurrency is in the `group.addTask` closures — each scope fetch runs concurrently.
The `for await` body merely collects results as they arrive; the append is the correct
and idiomatic pattern. There is no performance issue.

**Verify at:** `Sources/RunnerBarCore/Runner/RunnerPoller.swift` —
`fetchAndEnrichRunners` Phase 1, the `withTaskGroup` block.

---

## 10. `buildJobState` / `buildGroupState` re-read `activeScopes` — mid-cycle scope drift

**Claim:** `buildJobState` and `buildGroupState` each call `await MainActor.run {
self.scopeStore.activeScopes }` independently rather than sharing the `scopesSnapshot`
captured at `fetch()` entry — a scope change mid-poll produces an inconsistent frame.

**Reality:** This is a pre-existing behaviour carried over from `RunnerStore`, not a
regression introduced by this PR. Scope changes also trigger `startObservingScopes →
start()`, so the inconsistent frame is immediately overwritten by the next poll cycle.
The one-cycle artefact is cosmetically harmless. Fixing it (adding a `scopes:` param
to both bridge calls) is a valid follow-up but is out of scope for this structural refactor.

**Verify at:** `Sources/RunnerBarCore/Runner/RunnerPoller+PollBridge.swift` —
`buildJobState` and `buildGroupState` scope reads.

---

## 11. `fetch()` is `public` but absent from `RunnerPollerProtocol`

**Claim:** `fetch()` is declared `public` on `RunnerPoller` but does not appear in
`RunnerPollerProtocol`. This asymmetry means callers through the protocol cannot drive
a single poll cycle, but callers holding the concrete type can — bypassing the intended
seam.

**Reality:** This is intentional. `fetch()` is accessible at `internal` scope
specifically to support test-driving a single poll cycle without spinning up the full
loop. `AppDelegate.runnerStore` is typed `(any RunnerPollerProtocol)?`, so production
call sites cannot reach `fetch()` directly. Adding `fetch()` to the protocol is the
right long-term call but requires `MockRunnerPoller` to also implement it — a broader
change deferred to a follow-up.

**Verify at:** `Sources/RunnerBarCore/Runner/RunnerPollerProtocol.swift` and
`Sources/RunnerBarCore/Runner/RunnerPoller.swift` — `fetch()` declaration.

---

## 12. `ObservationLoopTests` missing negative case for untracked properties

**Claim:** The test suite has no case verifying that `onChange` does not fire when a
property on the same `@Observable` object changes but was not read inside `observe`.
Without this, the `statusIconLoop` contract — only fire on `aggregateStatus` changes,
not on `rateLimitResetDate` changes — is untested.

**Reality:** The behaviour is guaranteed by `withObservationTracking` semantics in the
Swift standard library, not by our code. Writing this test would be testing Apple's
framework. It is a nice-to-have that fits alongside the `withConfirmation` timing
cleanup already tracked in #1570 — not a gap that should block this PR.

**Verify at:** `Tests/RunnerBarCoreTests/ObservationLoopTests.swift` — the three
existing test cases cover fire, re-registration, and dealloc.

---

## 13. `ActiveJob.status` compared to string literals — was a real bug, now fixed

**Status: fixed** in this PR.

`ActiveJob.status` is typed `JobStatus` (a strongly-typed enum with a `String` raw
value). The old `RunnerStore.nextPollInterval()` and `WorkflowContextMenuModifier`
compared it against string literals (`"in_progress"`, `"queued"`) rather than enum
cases. This compiled because `JobStatus: RawRepresentable<String>` allows
`== rawValue` comparisons, but it was semantically wrong — a raw-value rename
would silently break the cadence logic.

Both sites have been updated to use typed enum cases (`== .inProgress`, `== .queued`),
consistent with every other `JobStatus` comparison in the codebase
(e.g. `PollResultBuilder`, `elapsed`, `conclusionIcon`).

**Verify at:** `Sources/RunnerBarCore/Runner/RunnerPoller.swift` —
`nextPollInterval()` and `Sources/RunnerBar/Views/Components/WorkflowContextMenuModifier.swift` —
`JobContextMenuModifier.menuItems`.

---

## 14. `FailureHookRunner.evaluate(_:)` — dead code with `periphery:ignore`, no cancellation handle

**Claim:** `evaluate(_:)` is dead code; `periphery:ignore` actively suppresses static
analysis that would surface it; the inner `Task {}` is fire-and-forget with no stored
handle, so it cannot be cancelled if the method is ever wired incorrectly.

**Reality (partial):** The dead-code concern and the cancellation gap are both real
observations. This PR addresses them as follows:

- `periphery:ignore` is retained (Periphery must still be suppressed to compile), but
  the annotation is now accompanied by a `// TODO(#1573)` comment that ties it to a
  concrete open issue. The comment explicitly instructs future engineers to remove
  the annotation once a real call site exists.
- The doc-comment on `evaluate(_:)` now includes a **Cancellation note** explaining
  why fire-and-forget is acceptable for the intended one-shot app-launch path, and
  what to do if the method is ever wired to a longer-lived owner.
- The wiring constraint (`do NOT call from failureHookLoop`) remains prominently
  doc-commented and is now also cross-referenced in the PR traps doc.

**What is not fixed here:** the `group.repo` empty-scope gap (fix deferred to #1573,
which should be resolved before the first real call site is wired).

**Verify at:** `Sources/RunnerBar/Services/FailureHookRunner.swift` —
`evaluate(_:)`, the `TODO(#1573)` comment block and the updated doc-comment.
