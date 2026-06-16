# Project Principles

This document captures the engineering and design principles that govern the RunnerBar codebase. It is intended as a living reference for contributors and reviewers.

---

## Index

1. [Swift 6.2 + SwiftUI with Actor-Based Architecture](#1-swift-62--swiftui-with-actor-based-architecture)
2. [Async/Await and @Observable for Data Flow](#2-asyncawait-and-observable-for-data-flow)
3. [Typed Codable Models for Persisted Configuration](#3-typed-codable-models-for-persisted-configuration)
4. [Compiler-Enforced Concurrency Boundaries](#4-compiler-enforced-concurrency-boundaries)
5. [macOS 26 Tahoe Liquid Glass Aesthetic](#5-macos-26-tahoe-liquid-glass-aesthetic)
6. [Strict Value Semantics and Immutable Models](#6-strict-value-semantics-and-immutable-models)
7. [Protocol-Oriented Dependency Injection](#7-protocol-oriented-dependency-injection)
8. [Use-Case Pattern (Clean Architecture)](#8-use-case-pattern-clean-architecture)
9. [Structured Concurrency for Stateful Timers](#9-structured-concurrency-for-stateful-timers)
10. [Atomic Snapshot Pattern (Eliminating TOCTOU Races)](#10-atomic-snapshot-pattern-eliminating-toctou-races)
11. [Module-Level Transport Shim and URLSession Async](#11-module-level-transport-shim-and-urlsession-async)
12. [Link-Header Pagination](#12-link-header-pagination)
13. [Multi-Target Swift Package with Testable Core](#13-multi-target-swift-package-with-testable-core)
14. [XcodeGen for Reproducible Xcode Projects](#14-xcodegen-for-reproducible-xcode-projects)
15. [Static Code Quality Pipeline](#15-static-code-quality-pipeline)
16. [Actor-Per-Concern Isolation](#16-actor-per-concern-isolation)
17. [nonisolated for Safe Cross-Boundary Capture](#17-nonisolated-for-safe-cross-boundary-capture)
18. [withCheckedContinuation for Blocking I/O](#18-withcheckedcontinuation-for-blocking-io)
19. [AnyJSON Type-Erased Codec](#19-anyjson-type-erased-codec)
20. [Typed Error Discrimination with ExecuteResult](#20-typed-error-discrimination-with-executeresult)
21. [Human-Readable Config Writes](#21-human-readable-config-writes)

---

## 1. Swift 6.2 + SwiftUI with Actor-Based Architecture

RunnerBar is built entirely in Swift 6.2 using SwiftUI, with a modern actor-based architecture that keeps all UI state on the `MainActor` and background work fully isolated in dedicated actors. This makes the concurrency model explicit, auditable, and enforced at compile time — not a convention that relies on developer discipline at runtime.

---

## 2. Async/Await and @Observable for Data Flow

Data flow is driven by Swift's native `async`/`await` and `@Observable`, giving SwiftUI precise, fine-grained updates with minimal overhead. `@Observable` replaces the older `ObservableObject` + `@Published` pattern, removing the need for manual `objectWillChange` calls and reducing spurious view re-renders.

---

## 3. Typed Codable Models for Persisted Configuration

Persisted configuration is handled through typed `Codable` models rather than raw dictionaries or `UserDefaults` string keys. This means the compiler validates the shape of all serialised data and decoding failures surface as structured errors — not silent `nil` values or runtime crashes.

---

## 4. Compiler-Enforced Concurrency Boundaries

The compiler enforces all concurrency boundaries throughout the codebase. There are no `@unchecked Sendable` escape hatches in production types; every actor crossing is visible at the call site. This makes data-race safety a build-time guarantee rather than a testing-time hope.

---

## 5. macOS 26 Tahoe Liquid Glass Aesthetic

The visual design embraces the macOS 26 Tahoe Liquid Glass aesthetic, so RunnerBar feels like a natural extension of the OS. UI components are built to match the translucency, material hierarchy, and motion vocabulary introduced in macOS 26, rather than layering a custom design language on top.

---

## 6. Strict Value Semantics and Immutable Models

`RunnerModel` and related domain types are fully immutable structs — every property is `let`, and `Sendable` conformance is synthesised by the compiler without any `@unchecked` escape hatch. Mutations produce new values through a `copying(…)` method that uses the double-optional `Optional<Optional<T>>` pattern to distinguish "set to nil" from "leave unchanged". This eliminates shared-mutable-state data races by construction rather than by convention.

---

## 7. Protocol-Oriented Dependency Injection

Concrete types are never referenced directly across module boundaries where testability matters. Instead, `protocol`-typed dependencies (`RunnerConfigStoreProtocol`, `RunnerProxyStoreProtocol`, `RunnerLabelsService`) are injected at construction time. This makes every use-case fully testable in isolation with real implementations in production and lightweight fakes in tests — no method-swizzling or singleton-patching required.

---

## 8. Use-Case Pattern (Clean Architecture)

Business logic is encapsulated in dedicated `Sendable` use-case structs (e.g. `SaveRunnerEditsUseCase`) that own a single, well-scoped transaction. Each use-case documents its error semantics explicitly: which steps abort on failure, which accumulate errors and continue, and why. This separates business logic cleanly from both the view layer and the persistence layer, and makes the error contract visible at the type level rather than buried in call-site comments.

---

## 9. Structured Concurrency for Stateful Timers

Timer-based state management uses structured concurrency (`Task` + `Task.sleep(for:)`) rather than `DispatchQueue.asyncAfter` or `DispatchWorkItem`. This makes timers natively cancellable, removes the need for `@unchecked Sendable` escape hatches, and keeps the timer lifecycle visible within the actor that owns the state. A `generation` counter guards against stale-task races, where a sleeping task wakes after a newer window has started and would otherwise incorrectly clear state that belongs to the newer window.

---

## 10. Atomic Snapshot Pattern (Eliminating TOCTOU Races)

Where multiple related values must be read consistently from an actor, they are always returned together in a single actor hop via a `snapshot()` method — never fetched with two separate `await` calls. This eliminates the time-of-check/time-of-use (TOCTOU) race window that exists between two independent hops, where state could change in between. The `RateLimitActor.snapshot()` method, which returns `isLimited` and `resetDate` atomically, is the canonical example of this pattern.

---

## 11. Module-Level Transport Shim and URLSession Async

All GitHub networking is funnelled through a private `urlSessionExecute` core function that handles token-guarding, URL resolution, rate-limit detection, and 403 disambiguation (genuine rate-limit vs. permission-denied) in one place. Public-facing functions (`ghAPI`, `ghAPIPaginated`, `urlSessionPost`, etc.) are thin wrappers that add no logic — they exist only to provide stable, named call sites for consumers. The transport uses `URLSession.shared.data(for:)` — the modern async variant — and returns a typed `ExecuteResult` enum rather than throwing, so call sites use clean pattern-matching `guard case .success` rather than `do/catch`.

---

## 12. Link-Header Pagination

Paginated GitHub API endpoints are consumed by following `Link: <url>; rel="next"` headers automatically, accumulating items across all pages into a single flat result. Mid-pagination authentication failures discard all partial results and return `nil` — because partial data from a broken auth session is worse than no data. Rate-limit hits during pagination return the partial results collected so far, since those items are valid and the rate-limit will clear. This distinction is deliberate and explicitly documented.

---

## 13. Multi-Target Swift Package with Testable Core

The project is structured as a pure Swift Package Manager project (`swift-tools-version: 6.2`) with a `RunnerBarCore` library target fully decoupled from the `RunnerBar` executable target, plus a dedicated `RunnerBarCoreTests` test target. The entire domain and networking layer can be unit-tested without instantiating any UI or app infrastructure, and the library/executable boundary is enforced by the package manifest — not just by convention.

---

## 14. XcodeGen for Reproducible Xcode Projects

Rather than committing the `.xcodeproj` bundle, the project uses XcodeGen (`project.yml`) to generate it deterministically from a human-readable specification. This eliminates merge conflicts in Xcode project files, keeps the repository diff-friendly, and ensures that the project file is always consistent with the source layout — it cannot drift independently.

---

## 15. Static Code Quality Pipeline

Dead-code elimination, style enforcement, and continuous quality analysis are all automated at CI time:

- **Periphery** (`.periphery.yml`) — detects unused types, functions, and properties at the compiler-graph level, not just by text search.
- **SwiftLint** (`.swiftlint.yml`) — enforces a project-specific style ruleset with custom rule configurations.
- **SonarCloud** (`sonar-project.properties`) — provides continuous quality gates, duplication analysis, and security scanning across every pull request.

All three run in CI, not just locally, so the quality bar is enforced unconditionally on every contribution.

---

## 16. Actor-Per-Concern Isolation

The concurrency model goes beyond a single background actor. Each mutable domain owns its own dedicated actor: `RateLimitActor` serialises all rate-limit state, and `RunnerConfigStore` is itself an actor that serialises all disk I/O for runner configuration files. The principle is one actor per mutable concern, zero shared mutable state anywhere — not one global "background actor" that everything piles into. This keeps actor contention minimal and makes ownership of each piece of state unambiguous.

---

## 17. nonisolated for Safe Cross-Boundary Capture

`JSONDecoder` instances are marked `nonisolated` on actors where they need to be captured inside closures that cross isolation boundaries. This is a deliberate, compiler-enforced acknowledgment that `JSONDecoder` has no mutable state after initialisation and is therefore safe to use across actor boundaries without synchronisation. It is not a workaround — it is a precise application of `nonisolated` to express an immutability guarantee that the compiler can then verify.

---

## 18. withCheckedContinuation for Blocking I/O

All synchronous disk I/O is bridged into the async world using `withCheckedContinuation` / `withCheckedThrowingContinuation`, dispatching the actual blocking work to `DispatchQueue.global(qos: .utility)`. This ensures the actor's cooperative thread is never blocked by a disk operation — a key Swift 6 correctness requirement for not starving the concurrency runtime. The pattern is: async surface, synchronous implementation, bridged explicitly at the boundary.

---

## 19. AnyJSON Type-Erased Codec

A custom `AnyJSON` enum in `Utilities/AnyJSON.swift` is used for read-modify-write operations on agent-managed config files (e.g. `.runner` JSON files that contain keys like `jitConfig` whose shape is controlled by GitHub, not by RunnerBar). `AnyJSON` allows the app to decode, mutate specific known keys, and re-encode the full file without losing unknown fields — and without resorting to `[String: Any]` or `JSONSerialization`. Everything remains `Codable` and type-safe end-to-end; unknown keys are preserved faithfully across round-trips.

---

## 20. Typed Error Discrimination with ExecuteResult

Mutation and fetch functions avoid throwing in favour of a private `ExecuteResult` enum that explicitly discriminates between `.success`, `.rateLimited`, `.permissionDenied`, `.httpError(Int)`, and `.networkError(Error)`. This keeps all response-handling logic in one exhaustive `switch` at the transport layer rather than scattered across call sites as nil-checks or catch blocks. Functions that return results callers may legitimately ignore are marked `@discardableResult`, making the intentional discard visible and compiler-validated rather than silent.

---

## 21. Human-Readable Config Writes

When writing `.runner` config files back to disk, `JSONEncoder` is configured with `.prettyPrinted` and `.sortedKeys`. This ensures that agent-managed configuration files remain human-readable and produce stable, minimal diffs in git — a key property when the files are shared between RunnerBar and the GitHub Actions runner agent. A config change that touches one field produces a one-line diff, not a reformatted blob.
