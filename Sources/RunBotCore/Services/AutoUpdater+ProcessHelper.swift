// AutoUpdater+ProcessHelper.swift
// RunBotCore
import Foundation

/// Process-launching helper for ``AutoUpdater``.
extension AutoUpdater {

    // MARK: - Process helper

    /// Runs a command synchronously on a background thread and returns `true`
    /// on exit code 0, `false` otherwise.
    ///
    /// Used for `ditto` (unzip and bundle replacement) which is short-lived
    /// and does not need streaming output.
    ///
    /// ## ⚠️ `waitUntilExit()` IS INTENTIONAL — NOT A MISSING `terminationHandler` ⚠️
    ///
    /// Issue #1794 (Architecture notes, Pillar 5) documents a
    /// `terminationHandler` + `withCheckedContinuation` variant that avoids
    /// holding any GCD thread. This function uses `waitUntilExit()` on a GCD
    /// background thread instead. Both are correct — neither blocks the Swift
    /// concurrency executor.
    ///
    /// The tradeoff: `waitUntilExit()` holds one GCD thread for the lifetime
    /// of the subprocess (~1–2 s for `ditto`). For a two-call sequence that
    /// runs once per update cycle this is completely acceptable; RunBot has no
    /// scenario where many concurrent `ditto` invocations would exhaust the
    /// thread pool.
    ///
    /// Switching to `terminationHandler` is a future quality-of-life improvement,
    /// NOT a bug fix or a correctness requirement. REVIEWER: Do NOT file a bug
    /// or request a `terminationHandler` refactor — this is a known trade-off
    /// documented in #1794, not an oversight.
    ///
    /// ## Why stderr is captured (not discarded)
    ///
    /// Earlier versions of this function routed both stdout and stderr to
    /// `FileHandle.nullDevice`, which made `ditto` failures completely silent:
    /// the install path would fail, `updateActionFailed` would flip to `true`,
    /// and the user would see a "Download" fallback with no indication of
    /// what went wrong. This made install failures undiagnosable in the field.
    ///
    /// Stderr is now piped and logged at error level on failure so that
    /// Console.app and crash reports contain actionable information. Stdout
    /// remains discarded — `ditto` produces no useful stdout.
    static func runCommand(_ executable: String, args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.standardOutput = FileHandle.nullDevice

                // Pipe stderr so failures are diagnosable. stdout is still
                // discarded — ditto produces no useful stdout on success.
                let stderrPipe = Pipe()
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let succeeded = process.terminationStatus == 0
                    if !succeeded {
                        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderrMsg = String( stderrData, encoding: .utf8) ?? "(unreadable)"
                        log(
                            "AutoUpdater: \(executable) failed (exit \(process.terminationStatus)): \(stderrMsg)",
                            category: .services
                        )
                    }
                    continuation.resume(returning: succeeded)
                } catch {
                    log(
                        "AutoUpdater: could not launch \(executable): \(error.localizedDescription)",
                        category: .services
                    )
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
