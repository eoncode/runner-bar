// RunnerStore+PollLoop.swift
// RunnerBar
import Foundation

// MARK: - Poll loop (see RunnerStore.swift)
//
// NOTE: Swift's `private` access is file-scoped, not type-scoped.
// Moving the poll loop here would require making `pollTask`,
// `intervalCancellable`, `scopeCancellable`, and `nextPollInterval()`
// `internal`, which widens their visibility across the entire module.
//
// The poll loop therefore lives in RunnerStore.swift, where it can
// remain `private`. This file serves as an intentional placeholder
// that marks the logical boundary — if Swift ever gains extension-scoped
// `private` (or if the properties are refactored into a sub-object),
// the migration target is here.
//
// Relevant properties and methods (currently in RunnerStore.swift):
//   - var pollTask: Task<Void, Never>?
//   - var intervalCancellable: AnyCancellable?
//   - var scopeCancellable: AnyCancellable?
//   - func start()
//   - func nextPollInterval() -> TimeInterval
//   - deinit
