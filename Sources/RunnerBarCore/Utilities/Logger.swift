// Logger.swift
// RunnerBarCore
import Foundation
import os

// MARK: - Unified logging
//
// log() is the single call-site throughout the app.
// Backed by os.Logger so messages appear in Console.app with
// subsystem/category filtering and are zero-cost in release builds
// (.debug level is compiled out by the OS when not actively streaming).

// MARK: - Log categories

/// Logical subsystem categories for `os.Logger` filtering in Console.app
/// and `log stream --predicate`.
public enum LogCategory: String, CaseIterable {
    /// Fallback / uncategorised (migration default).
    case general
    /// GitHub transport, auth and API layers.
    case transport
    /// Runner polling, stores, services and models.
    case runner
    /// Scope store and preferences.
    case scope
    /// OS-level services: Keychain, LoginItem, ProcessRunner,
    /// TerminalLauncher, LogFetcher.
    case services
    /// Failure-hook use-case.
    case failureHook
}

// MARK: - Logger instances

/// The OSLog subsystem identifier for the app, shared across all log categories.
private let subsystem = "com.eoncode.runner-bar"

/// One `os.Logger` per `LogCategory`, created once at launch.
///
/// Built from `LogCategory.allCases` via `uniqueKeysWithValues`, so the dictionary
/// is guaranteed to contain every current case at the time this line executes.
/// `resolvedLogger(for:)` depends on this invariant and uses `fatalError` (not
/// `preconditionFailure`) if a key is ever missing — see that function for the
/// detailed rationale.
///
/// `nonisolated(unsafe)` suppresses the `#MutableGlobalVariable` warning that Swift 6
/// strict-concurrency mode emits for top-level `let` bindings of non-`Sendable` types.
/// This dictionary is initialised once during module load and never mutated, making it
/// safe to read from any concurrency domain without an explicit isolation annotation.
nonisolated(unsafe) private let loggers: [LogCategory: Logger] = Dictionary(
    uniqueKeysWithValues: LogCategory.allCases.map { category in
        (category, Logger(subsystem: subsystem, category: category.rawValue))
    }
)

/// Returns the `os.Logger` for the given category.
///
/// Under normal operation this function always succeeds: `loggers` is built from
/// `LogCategory.allCases` via `uniqueKeysWithValues`, guaranteeing every case is
/// present. The `guard` branch is therefore structurally unreachable at runtime.
///
/// **Why `fatalError` and not `preconditionFailure`?**
/// `preconditionFailure` is eliminated by the optimiser in `-Ounchecked` release
/// builds, making it invisible in App Store / notarised binaries. `fatalError` is
/// never stripped — it fires in every build configuration. Because a missing entry
/// can only arise from a programmer error (adding a `LogCategory` case without
/// re-checking this file), it should crash loudly everywhere, not just in debug.
/// The crash message names the missing category so the fix is self-evident.
///
/// **Why not `assertionFailure` + a silent fallback logger?**
/// A silent fallback would silently allocate a new `os.Logger` instance on every
/// `log()` call for the unrecognised category, producing log output under the wrong
/// (or empty) category string with no indication anything is wrong. That failure
/// mode is harder to diagnose than an immediate crash.
@inline(__always)
private func resolvedLogger(for category: LogCategory) -> Logger {
    // This guard is structurally unreachable — see doc comment above for rationale.
    guard let logger = loggers[category] else {
        fatalError("Logger for category '\(category.rawValue)' not found — add it to LogCategory.allCases")
    }
    return logger
}

// MARK: - Public log() entry-point

/// Writes a debug-level message to the unified logging system.
///
/// Messages are visible in:
///   - Console.app (filter by subsystem: com.eoncode.runner-bar, then by category)
///   - `log stream --level debug --predicate 'subsystem == "com.eoncode.runner-bar"'`
///   - Xcode debug console when running from Xcode
///
/// In release builds the OS elides .debug calls at zero cost.
///
/// - Parameters:
///   - message:  Human-readable log message.
///   - category: Subsystem category for Console.app filtering.
///               Defaults to `.general` so existing call sites compile unchanged.
public func log(
    _ message: String,
    category: LogCategory = .general,
    file: String = #file,
    line: Int = #line
) {
    let filename = URL(fileURLWithPath: file)
        .deletingPathExtension().lastPathComponent
    resolvedLogger(for: category).debug(
        "\(filename, privacy: .public):\(line, privacy: .public) — \(message, privacy: .public)"
    )
}
