// RunnerStore+PollLoop.swift
// RunnerBar
//
// Migration boundary established in PR #1256 (closed 2026-06-09) and
// superseded by the PollLoopCoordinator extraction in this PR (PR-D).
//
// The poll-loop methods (`start`, `nextPollInterval`, `startObservingPreferences`,
// `startObservingScopes`) remain in `RunnerStore.swift` because they are `private`
// and therefore file-scoped. Moving them here would require widening them to
// `internal`. This is deferred until Swift gains extension-scoped `private` access.
//
// The three `Task?` handles that back those methods are owned by `PollLoopCoordinator`
// (`private let pollLoop` on `RunnerStore`) — that type provides the extraction
// boundary the architecture needs without requiring access-level widening.
//
// Combine dependency removed: `intervalCancellable` and `scopeCancellable`
// (AnyCancellable) have been replaced by structured `Task`-based observation.
// There are no remaining Combine imports in `RunnerStore.swift`.
import Foundation
