// RunnerPollerObservers.swift
// RunBot
//
// Step 10: Moved from RunBot app target to RunBotCore.
// F-35: PreferencesObserver and ScopesObserver replaced by ObservationRelay<Element>.
// F-26: log calls use category: parameter (per-subsystem logger).

import Foundation

// MARK: - Typealiases

/// Drives the `pollingInterval → TimeInterval` observation stream.
///
/// Alias for `ObservationRelay<TimeInterval>` — preserves call-site names in
/// `RunnerPoller` so the F-35 refactor requires no renaming diff outside this file.
///
/// - Note: `internal` to match original visibility. Do not narrow to `private`
///   (breaks cross-file reference) or widen to `public` (unnecessary API surface).
typealias PreferencesObserver = ObservationRelay<TimeInterval>

/// Drives the `activeScopes → [String]` observation stream.
///
/// Alias for `ObservationRelay<[String]>` — preserves call-site names in
/// `RunnerPoller` so the F-35 refactor requires no renaming diff outside this file.
///
/// - Note: `internal` to match original visibility. Do not narrow to `private`
///   (breaks cross-file reference) or widen to `public` (unnecessary API surface).
typealias ScopesObserver = ObservationRelay<[String]>
