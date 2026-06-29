# Reach Goal Principles

This document captures aspirational engineering principles for RunBot — modern Swift 6.0–6.2 patterns and language features that are not yet adopted but represent the next frontier of code quality, safety, and expressiveness. These are deliberate stretch goals rather than current requirements.

---

## Index

1. [Swift Testing Framework (@Test, #expect)](#1-swift-testing-framework-test-expect)
2. [Observations Async Sequence for State Streaming](#2-observations-async-sequence-for-state-streaming)
3. [Access Control for Imports (internal import)](#3-access-control-for-imports-internal-import)
4. [Typed Throws at Domain Boundaries](#4-typed-throws-at-domain-boundaries)
5. [Isolated Synchronous deinit](#5-isolated-synchronous-deinit)
6. [Task Naming and Priority Escalation](#6-task-naming-and-priority-escalation)
7. [@attached(body) Macros for Cross-Cutting Concerns](#7-attachedbody-macros-for-cross-cutting-concerns)
8. [@concurrent for Explicit Background Offloading](#8-concurrent-for-explicit-background-offloading)
9. [Opt-In Strict Memory Safety Mode](#9-opt-in-strict-memory-safety-mode)
10. [Ownership Annotations (borrowing / consuming)](#10-ownership-annotations-borrowing--consuming)
11. [Typed Throws for Domain Error Contracts](#11-typed-throws-for-domain-error-contracts)
12. [nonisolated(nonsending) for Caller-Context Async Functions](#12-nonisolatednonsending-for-caller-context-async-functions)
13. [Mutex for Synchronous Low-Contention Shared State](#13-mutex-for-synchronous-low-contention-shared-state)
14. [sending Parameters for Non-Sendable Cross-Isolation Transfer](#14-sending-parameters-for-non-sendable-cross-isolation-transfer)
15. [consuming / borrowing on Value-Type Pipelines](#15-consuming--borrowing-on-value-type-pipelines)

---

## 1. Swift Testing Framework (@Test, #expect)

The project enforces CI-gated tests, but the principles document does not yet define *how* tests are written. Swift Testing (shipped with Swift 6.0) replaces `XCTestCase` with macro-based `@Test` functions, `#expect` assertions, and `@Suite` groupings. Test structs receive a fresh instance per test with no shared state, which aligns directly with the value-semantics principle already adopted in the core library. Parameterised tests via `@Test(arguments:)` replace repetitive test methods, reducing duplication at the assertion level and making coverage of edge cases explicit and diffable.

**Principle:** All new tests are written using Swift Testing (`@Test`, `#expect`, `@Suite`). `XCTestCase` is treated as legacy and migrated opportunistically. Parameterised inputs are preferred over duplicated single-case test functions.

---

## 2. Observations Async Sequence for State Streaming

Swift 6.2 adds `Observations<Value>` — an `AsyncSequence` that streams transactional snapshots of `@Observable` properties. Each emission represents a consistent state at an `await` boundary, not individual property mutations, so observers never see a half-updated model. This is a direct upgrade to the existing `@Observable` data flow principle and eliminates the need for manual `withObservationTracking` polling loops in non-SwiftUI consumers.

**Principle:** Reactive state consumers outside of SwiftUI views use `Observations` async sequences rather than polling or manual `withObservationTracking` callbacks. Each consumed value represents a complete, consistent model snapshot.

---

## 3. Access Control for Imports (internal import)

Swift 6.0 introduced `internal import` and `package import` as formal access control on import declarations. The `RunBotCore` library can explicitly prevent implementation-detail dependencies from leaking into its public API surface — enforced by the compiler, not by convention. This complements the Multi-Target Package principle by making the dependency graph of the library as auditable as its type graph.

**Principle:** All imports in `RunBotCore` are annotated with the minimum required access level (`internal import` or `private import` for implementation details). Public re-export of transitive dependencies is never implicit.

---

## 4. Typed Throws at Domain Boundaries

Typed throws (`throws(DomainError)`) matured across Swift 6.0–6.2. The principle is narrow and deliberate: use typed throws at use-case and service layer boundaries where the error set is closed and stable, and keep untyped `throws` at the transport layer where errors are structurally open. The existing `ExecuteResult` enum already captures this intent at the transport layer — the missing half is a symmetrical, typed-throw contract for `UseCase` structs so callers receive exhaustive-switch guarantees from the compiler.

**Principle:** Use-case `execute()` methods throw a dedicated, closed error enum (e.g. `throws(RunnerEditError)`). Transport functions retain untyped `ExecuteResult` returns. The boundary between the two is explicit and documented per use-case.

---

## 5. Isolated Synchronous deinit

Swift 6.2 adds `isolated deinit`, allowing actor-isolated cleanup code to run on the actor itself rather than on an arbitrary thread. Without this, actor deinit runs off-actor and resource teardown requires workarounds such as explicit `invalidate()` methods or detached cleanup tasks. This closes a gap in the structured concurrency model for actors that own file handles, network sessions, or timer tasks.

**Principle:** Actors that own resources with teardown requirements (file handles, open network sessions, running `Task` trees) use `isolated deinit` for deterministic, on-actor cleanup. Explicit `invalidate()` patterns are a fallback, not the default.

---

## 6. Task Naming and Priority Escalation

Swift 6.2 introduced Task naming via `Task(name:)` and Task Priority Escalation APIs (SE-0462). Task names surface in Instruments and crash logs, making structured concurrency trees debuggable by name rather than by opaque memory address. Priority escalation allows a high-priority awaiter to boost the priority of the task it is blocked on, preventing priority inversion in interactive workflows such as user-triggered runner refresh.

**Principle:** All long-lived or structurally significant tasks are created with a descriptive `name:` parameter. Tasks that serve user-interactive paths are created at `.userInitiated` priority so escalation can propagate correctly.

---

## 7. @attached(body) Macros for Cross-Cutting Concerns

Swift 6.0 added `@attached(body)` macros that synthesise or augment function implementations, not just declarations. This makes it practical to attach cross-cutting behaviours — logging, timing, retry logic — to use-case `execute()` methods without subclassing or decorator boilerplate. Combined with `@attached(peer)` and `@attached(conformance)`, custom macros can auto-generate protocol + fake test double pairs from a concrete type declaration, eliminating manual protocol mirroring.

**Principle:** Cross-cutting concerns (telemetry, retry, logging) are implemented as `@attached(body)` macros rather than base classes or manual wrapper types. Custom macros live in a dedicated `RunBotMacros` target and are tested independently using `swift-syntax`'s macro testing utilities.

---

## 8. @concurrent for Explicit Background Offloading

Swift 6.2 introduced the `@concurrent` attribute as a first-class way to mark async functions that must execute on a background executor, independent of the caller's isolation. This is the modern, expressive alternative to marking functions `nonisolated` purely to escape the `MainActor` — it makes the intent unmistakably clear at the declaration site and removes ambiguity about which actor a function runs on.

**Principle:** Async functions that perform CPU-bound or latency-sensitive background work are annotated `@concurrent` rather than relying on `nonisolated` as an indirect mechanism. The isolation domain of every async function is explicit at its declaration.

---

## 9. Opt-In Strict Memory Safety Mode

Swift 6.2 adds a `-strict-memory-safety` compiler flag that audits every use of unsafe constructs in a module, introducing `@unsafe` / `@safe` annotations and an `unsafe` expression keyword analogous to `try` and `await`. This makes unsafe call sites explicit and auditable at the source level — the same philosophy that strict concurrency checking applied to data races. Given the existing principle of making all concurrency boundaries visible at the call site, enabling this flag on `RunBotCore` is the natural extension.

**Principle:** `RunBotCore` is compiled with `-strict-memory-safety`. Any use of unsafe APIs is marked with the `unsafe` expression keyword at the call site, making the safety contract explicit and reviewable. New unsafe call sites require a comment justifying why no safe alternative exists.

---

## 10. Ownership Annotations (borrowing / consuming)

The `borrowing` and `consuming` parameter modifiers express ownership intent on value-type parameters, allowing the compiler to eliminate ARC overhead and unnecessary copies. For immutable `RunnerModel` structs passed across actor boundaries, annotating pure read functions with `borrowing` and irreversible transformation functions with `consuming` turns copy-elimination from an optimiser guess into a compiler-verified contract. This is a direct extension of the Strict Value Semantics principle already in place.

**Principle:** Hot-path functions that receive large value types and do not mutate them are annotated `borrowing`. Functions that definitively end the lifetime of a value are annotated `consuming`. These annotations are treated as part of the function's documented contract, not as internal implementation hints.

---

## 11. Typed Throws for Domain Error Contracts

The codebase already defines well-scoped error enums (`RunnerConfigStoreError`, `RunnerProxyStoreError`) and uses `ExecuteResult` for network-layer errors, but no principle codifies typed throws at the function signature level. Swift 6.2's `throws(MyError)` gives the compiler a static guarantee that a function can only throw the declared type — no type erasure, no `catch { }` escape hatch for `any Error`. For a codebase with bounded, stable error enums this is a natural fit: `func save() async throws(RunnerConfigStoreError)` is more precise than `func save() async throws`, and call sites get exhaustive `switch` coverage enforced at compile time.

**Principle:** Typed throws are used on all non-network domain boundaries where the error set is closed and owned by the module. Untyped `throws` is reserved for call sites that must forward an arbitrary `Error` across module or abstraction boundaries. The choice between the two is explicit and documented per function.

---

## 12. nonisolated(nonsending) for Caller-Context Async Functions

Swift 6.2 introduces `nonisolated(nonsending)` (SE-0461), where a `nonisolated` async function runs on the *caller's* executor rather than hopping to the global cooperative pool. The codebase uses `nonisolated` on `JSONDecoder` properties (P17) but has no principle governing the executor behaviour of `nonisolated` async functions. Without the `NonIsolatedNonSendingByDefault` feature flag or explicit annotations, `nonisolated` async helpers may silently hop off `@MainActor` when called from it — exactly the kind of invisible context switch that causes subtle timing bugs.

**Principle:** All `nonisolated` async functions are explicitly annotated as either `nonisolated(nonsending)` (to inherit the caller's isolation context) or `@concurrent` (to explicitly run on the global cooperative pool). Implicit executor behaviour for `nonisolated` async functions is never relied upon. The `NonIsolatedNonSendingByDefault` feature flag is enabled at the package level once the codebase is fully annotated.

---

## 13. Mutex for Synchronous Low-Contention Shared State

P16 mandates actors for mutable domains, which is correct for async-heavy types. `Synchronization.Mutex` (available since Swift 6.0, production-stable in 6.2) is the right tool when the guarded operation is synchronous and fast (e.g. a token cache read or a counter increment), making the entire call site `async` just to use an actor is disproportionate overhead, and the type needs to be `Sendable` without actor isolation. A `Mutex<CachedToken?>` for an in-memory Keychain token cache is cleaner and faster than a dedicated actor — the lock is taken, the value is read or written, and the lock is released, all without suspending or allocating a continuation.

**Principle:** `Synchronization.Mutex` is preferred over actors for synchronous, fast-path, low-contention shared state where the protected operation completes without `await`. Actors are preferred when the protected operations are async, involve I/O, or require structured concurrency lifecycle management.

---

## 14. sending Parameters for Non-Sendable Cross-Isolation Transfer

Swift 6's `sending` keyword (SE-0430) allows a non-`Sendable` value to cross an isolation boundary when the compiler can prove the caller's region no longer holds a reference after the call. Currently, anything crossing actor boundaries must be `Sendable` — which can force either `@unchecked Sendable` on types that are not fully safe, or unnecessary wrapping of values. The `sending` keyword is a precision tool: `func process(_ draft: sending RunnerEditDraft)` tells the compiler that ownership transfers at this call site, and the caller cannot access the value afterwards — no `Sendable` conformance required.

**Principle:** `sending` is used on function parameters where a non-`Sendable` value is intentionally transferred across an isolation boundary and the caller genuinely relinquishes access. This is preferred over adding `@unchecked Sendable` to a type solely to enable the transfer. The use of `sending` is treated as an ownership contract, not a compiler workaround.

---

## 15. consuming / borrowing on Value-Type Pipelines

The domain types (`RunnerModel`, `RunnerConfig`, `RunnerProxyConfig`) are already immutable `let`-only structs per P6. The next step is ownership annotations at their call sites. `borrowing` on a parameter expresses "I am reading this value; no copy, no retain". `consuming` on a method expresses "this instance is done after this call". For a `RunnerEditDraft` that is built up and then committed exactly once via `SaveRunnerEditsUseCase`, the entry point can be `consuming func commit()` — making it a compile error to reuse a draft after committing. For high-frequency read paths (e.g. processing arrays of `WorkflowActionGroup`), `borrowing` parameters eliminate hidden ARC copies that accumulate under load.

**Principle:** `consuming` is applied to single-use finaliser methods on value types where reuse after the call is a logic error. `borrowing` is applied to read-only parameters on hot-path functions where ARC copy elimination is measurable or architecturally important. Both annotations are treated as part of the function's public contract, not as internal optimisation hints.

---

*This document is intentionally aspirational. Principles graduate to `project-principles.md` once adopted consistently across the codebase.*
