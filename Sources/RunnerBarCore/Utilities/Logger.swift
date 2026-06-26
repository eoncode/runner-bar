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
/// is guaranteed to contain every current case. `resolvedLogger(for:)` depends on this
/// invariant — if a new case is added without updating this initialiser the force-unwrap
/// below will crash at the first call site in debug builds, surfacing the omission
/// immediately rather than silently allocating a new `Logger` instance per log call.
private let loggers: [LogCategory: Logger] = Dictionary(
    uniqueKeysWithValues: LogCategory.allCases.map {
        ($0, Logger(subsystem: subsystem, category: $0.rawValue))
    }
)

/// Returns the `os.Logger` for the given category.
///
/// Force-unwraps the dictionary subscript because `loggers` is built from
/// `LogCategory.allCases` and is therefore guaranteed to contain every case.
/// A nil result would mean a `LogCategory` case was added without a corresponding
/// entry in `loggers` — a programmer error that should crash loudly in development
/// rather than silently allocate a new `Logger` instance on every log call.
@inline(__always)
private func resolvedLogger(for category: LogCategory) -> Logger {
    // allCases guarantees every case is present; subscript will never return nil.
    loggers[category]!
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
