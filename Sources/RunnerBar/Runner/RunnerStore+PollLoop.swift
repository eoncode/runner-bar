// RunnerStore+PollLoop.swift
// RunnerBar
//
// Migration status: PLACEHOLDER — poll loop not yet extracted.
//
// The poll loop (start, nextPollInterval, pollTask, intervalCancellable,
// scopeCancellable, deinit) currently lives in RunnerStore.swift because
// Swift's `private` access is file-scoped, not type-scoped. Extracting
// those members here would require widening them to `internal`, exposing
// them across the entire module.
//
// This file marks the intended extraction boundary. Once either:
//   a) Swift gains extension-scoped `private`, or
//   b) the poll-loop state is encapsulated in a dedicated sub-object,
// the members below can be moved here without widening their access.
//
// TODO: Complete poll-loop extraction — tracked in PR #1256.
//       Members to migrate (currently in RunnerStore.swift):
//         - var pollTask: Task<Void, Never>?
//         - var intervalCancellable: AnyCancellable?
//         - var scopeCancellable: AnyCancellable?
//         - func start()
//         - func nextPollInterval() -> TimeInterval
//         - deinit
import Foundation
