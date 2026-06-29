***

## The Swift Concurrency Lexicon

The complete glossary of Swift concurrency terms, grounded in how they are actually used in the `run-bot` codebase.

***

## `actor`

An `actor` is a reference type that protects its own mutable state by serialising all access to it — only one piece of code can be inside an actor at a time . Think of it as a room with a single-occupancy lock: callers queue up and enter one at a time. In run-bot, the principle is **one actor per mutable concern** (P16): `RateLimitActor` owns rate-limit state, `RunnerConfigStore` owns disk I/O — nothing shares a single global background actor . The compiler enforces this; accessing an actor's state from outside always requires `await`.

***

## `@MainActor`

`@MainActor` is a special built-in actor that represents the main thread . Annotating a type or function `@MainActor` tells the compiler it must only run there. All SwiftUI views and ViewModels in run-bot are `@MainActor`-isolated. The important implication: if you call a `@MainActor` function from a background context, the compiler forces you to `await` it — making every thread hop visible and explicit .

***

## `MainActor.run { }`

`MainActor.run { }` is how you hop *to* the main actor from a background context for a single synchronous block of work, then return . In run-bot it's used like this in background tasks:

```swift
let scopes = await MainActor.run { scopeStore.activeScopes }
```

It's a targeted hop — read one thing on the main thread, come back — rather than annotating the entire function `@MainActor` .

***

## `Sendable`

`Sendable` is a protocol (really a compiler marker) that says: *this type is safe to pass across actor boundaries* . Value types like `struct` and `enum` with only `let` properties get it for free. Reference types need manual conformance. In run-bot, `RunnerModel` is a fully immutable `Sendable` struct — every property is `let`, and the compiler synthesises conformance automatically, no `@unchecked` needed . Use-case types like `WorkflowActionsUseCase` are also `Sendable` structs, which is what allows them to be safely called from any isolation context .

***

## `nonisolated`

`nonisolated` means: *this method/property does not belong to the actor's serial executor — it can be called from anywhere without `await`* . It's an opt-out from actor isolation. In run-bot it's used on `JSONDecoder` instances on actors: because `JSONDecoder` has no mutable state after init, marking it `nonisolated` is a precise, compiler-checked immutability declaration — not a workaround . An important Swift 6.2 refinement: `nonisolated` async functions still hop to the cooperative thread pool by default, which is why the reach-goal principles introduce `nonisolated(nonsending)` to *inherit the caller's* executor instead .

***

## `async` / `await`

`async` marks a function as one that can suspend — it can pause execution and give the thread back to the system while waiting . `await` is the call site marker: *here is a potential suspension point*. Every `await` makes a thread hop visible in source code. The key insight: `await` does not mean "run on a background thread" — it means "the compiler acknowledges a suspension point here." Where the code actually *runs* is determined by the isolation context .

***

## `Task { }`

A plain `Task { }` spawns a new unit of async work that *inherits the isolation context of its creator* . If you write `Task { }` inside a `@MainActor` function, the task body runs on `@MainActor`. In run-bot, SwiftUI views use plain `Task { }` for this exact reason — isolation is inherited automatically, no annotation needed . The task is unstructured (not in a hierarchy), so you must cancel it manually (stored as `pollTask`, `signInTask`, etc.).

***

## `Task.detached { }`

`Task.detached { }` creates a task that is *completely independent* — it does not inherit the caller's actor isolation, priority, or task-local values . It's intentionally orphaned. In run-bot, `LogFetcher`'s entry points are called from `Task.detached` contexts, which is why they are `async` but not `@concurrent` . Use it when you explicitly *don't* want to carry forward the caller's context. It's rarer than plain `Task {}` and should be deliberate.

***

## Background `Task` / Background Actor

These are informal terms. A **background task** just means a `Task` running outside the `@MainActor` — either via `Task.detached`, or via a plain `Task` started from a non-`@MainActor` context. A **background actor** means a custom actor (not `@MainActor`) that runs on Swift's cooperative thread pool, like `RateLimitActor` or `RunnerConfigStore` . Both are fully managed by the Swift runtime — no manual thread creation.

***

## `withTaskGroup`

`withTaskGroup` creates a **structured** group of child tasks that all run concurrently and are collected back at a single point . It's the safe, cancellation-aware alternative to spinning up multiple independent `Task`s and hoping they finish. In run-bot, `WorkflowActionGroupFetch` uses `withTaskGroup` to fan out parallel GitHub API fetches per scope and collect the results . When the group scope exits, all children are awaited — no orphaned work.

***

## `async let`

`async let` is lightweight structured parallelism for a known, fixed number of concurrent operations . Compared to `withTaskGroup` (dynamic number of tasks), `async let` is for when you know exactly what you want to run in parallel:

```swift
async let fetchedOrgs = fetchUserOrgs()
async let fetchedRepos = fetchUserRepos()
let (orgs, repos) = await (fetchedOrgs, fetchedRepos)
```

Both fetches start immediately, run concurrently, and are joined at the `await` . Used in `AddScopeSheet` for parallel org/repo fetches.

***

## `@concurrent`

`@concurrent` (Swift 6.2) marks an `async` function as one that explicitly runs on the cooperative thread pool's background executor, regardless of the caller's isolation . It's the modern alternative to `nonisolated` for "I want to run off any actor." In run-bot it's used for blocking disk I/O helpers — a `@concurrent` function doing `Data(contentsOf:)` can't stall the actor that called it, because it runs on a separate worker thread . Important: it's an *isolation* solution, not a *non-blocking I/O* solution — the thread is still occupied during the blocking call .

***

## `withCheckedContinuation` / `withCheckedThrowingContinuation`

These bridge **callback-based APIs** into the async world . You get a `continuation` object, hand it into a completion-handler API, and the `resume(returning:)` call on it wakes your suspended async function. In run-bot this is explicitly considered **legacy** and being migrated away from — `@concurrent` is the preferred replacement for new code . `ProcessRunner` retains it because it needs a `DispatchQueue.sync` barrier as a deliberate join point, which has no `@concurrent` equivalent .

***

## `snapshot()` — Atomic Snapshot Pattern (P10)

Not a language keyword — a **design pattern** enforced throughout run-bot . When you need multiple related values from an actor, fetching them with two separate `await` calls creates a TOCTOU (time-of-check/time-of-use) race: state can change between the two hops. Instead, a `snapshot()` method returns all related values together in a single actor hop, atomically . `RateLimitActor.snapshot()` returning `(isLimited, resetDate)` together is the canonical example — one hop, consistent data, no race window .

***

## Quick Reference

| Term | Where it runs | Inherits isolation? | Structured? |
|---|---|---|---|
| `actor` | its own serial executor | N/A | N/A |
| `@MainActor` | main thread | yes (if annotated) | N/A |
| `Task { }` | inherits caller | ✅ yes | ❌ no |
| `Task.detached { }` | cooperative pool | ❌ no | ❌ no |
| `withTaskGroup` | cooperative pool | ✅ yes | ✅ yes |
| `async let` | cooperative pool | ✅ yes | ✅ yes |
| `@concurrent func` | cooperative pool | ❌ no (by design) | N/A |
| `MainActor.run { }` | main thread | N/A (explicit hop) | N/A |
| `withCheckedContinuation` | bridge to any callback | depends on context | ❌ no |

The overarching principle in run-bot: every actor crossing is **visible at the call site** as an `await`, and the isolation domain of every function is explicit at its declaration — nothing is left to runtime convention .