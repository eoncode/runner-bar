// IndexedScopedRunner.swift
// RunnerBarCore

// MARK: - IndexedScopedRunner

/// Carries a scope-fetched `Runner` alongside its source-scope string.
/// Used internally by `fetchAndEnrichRunners` to pass data through two
/// concurrent `withTaskGroup` phases without a 3-member tuple
/// (which would trigger the `large_tuple` SwiftLint rule).
///
/// ⚠️ The ordering of entries in the `indexed` array after Phase 1 is
/// non-deterministic: `withTaskGroup` tasks complete in arrival order.
/// This matches the previous `RunnerStore` behaviour; views sort
/// runners independently for display.
///
/// `fileprivate` would be narrower than `internal`, but this type is
/// accessed from `RunnerPoller+FetchAndEnrich.swift` — a separate file
/// in the same module — so `fileprivate` would confine it to this file
/// only and cause a compile error in that extension. `internal` (the
/// default) is therefore the narrowest correct access level given the
/// cross-file usage. This type has no intended public API surface and
/// is an implementation detail of `RunnerPoller.fetchAndEnrichRunners`.
struct IndexedScopedRunner {
    /// The GitHub scope URL string (repo or org) this runner belongs to.
    /// Immutable after construction — only `runner` is mutated in Phase 2.
    let scope: String
    /// The enriched `Runner` value. Mutated in-place during Phase 2 to add metrics.
    var runner: Runner
}
