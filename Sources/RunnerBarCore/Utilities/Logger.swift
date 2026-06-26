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
    case general     = "general"
    /// GitHub transport, auth and API layers.
    case transport   = "transport"
    /// Runner polling, stores, services and models.
    case runner      = "runner"
    /// Scope store and preferences.
    case scope       = "scope"
    /// OS-level services: Keychain, LoginItem, ProcessRunner,
    /// TerminalLauncher, LogFetcher.
    case services    = "services"
    /// Failure-hook use-case.
    case failureHook = "failureHook"
}

// MARK: - Logger instances

private let subsystem = "com.eoncode.runner-bar"

/// One `os.Logger` per `LogCategory`, created once at launch.
private let loggers: [LogCategory: Logger] = Dictionary(
    uniqueKeysWithValues: LogCategory.allCases.map {
        ($0, Logger(subsystem: subsystem, category: $0.rawValue))
    }
)

/// Returns the `os.Logger` for the given category.
@inline(__always)
private func resolvedLogger(for category: LogCategory) -> Logger {
    loggers[category] ?? Logger(subsystem: subsystem, category: category.rawValue)
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
