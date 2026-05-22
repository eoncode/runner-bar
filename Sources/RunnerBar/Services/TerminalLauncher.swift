import Foundation

// MARK: - TerminalLauncher

// #546: Opens a normal Terminal.app window and runs the given command via AppleScript.
//
// Uses NSAppleScript + `do script` — requires no entitlements on an unsandboxed app.
// Escapes backslashes, double quotes, and newlines before embedding in the AppleScript string.
enum TerminalLauncher {
    /// Opens Terminal.app and runs `command` in a new window.
    static func open(command: String) {
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
            log("TerminalLauncher › AppleScript error: \(error ?? [:])")
        }
    }
}
