// TerminalLauncher.swift
// RunnerBarCore
import Foundation

/// Opens a Terminal.app window and runs a shell command via AppleScript (`do script`).
///
/// Uses `NSAppleScript` — requires no entitlements on an unsandboxed app.
/// Backslashes, double quotes, and newlines in the command are escaped before
/// embedding in the AppleScript string. Tracked in #546.
///
/// Moved from `RunnerBar` to `RunnerBarCore` in #1623.
public enum TerminalLauncher {
    /// Opens Terminal.app and runs `command` in a new window.
    public static func open(command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let src = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        if NSAppleScript(source: src)?.executeAndReturnError(&error) == nil {
            log("TerminalLauncher › AppleScript error: \(error ?? [:])", category: .services)
        }
    }
}
