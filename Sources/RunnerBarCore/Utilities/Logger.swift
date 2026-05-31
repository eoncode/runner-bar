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

/// Shared `os.Logger` instance used by all `log(_:)` call sites in RunnerBarCore.
private let logger = Logger(
    subsystem: "com.eoncode.runner-bar",
    category: "general"
)

/// Writes a debug-level message to the unified logging system.
///
/// Messages are visible in:
///   - Console.app (filter by subsystem: com.eoncode.runner-bar)
///   - `log stream --level debug --predicate 'subsystem == "com.eoncode.runner-bar"'`
///   - Xcode debug console when running from Xcode
///
/// In release builds the OS elides .debug calls at zero cost.
public func log(
    _ message: String,
    file: String = #file,
    line: Int = #line
) {
    let filename = URL(fileURLWithPath: file)
        .deletingPathExtension().lastPathComponent
    logger.debug("\(filename, privacy: .public):\(line, privacy: .public) — \(message, privacy: .public)")
}
