// RunnerProxyConfig.swift
// RunnerBarCore
// Moved from RunnerBar app target to RunnerBarCore in Phase 5 (#1300)
// so that test targets and the use case protocol can reference it.
import Foundation

// MARK: - RunnerProxyConfig

/// Typed value representing the proxy configuration stored in `.proxy`
/// and `.proxycredentials` files in a runner's install directory.
///
/// - `url`      — written to `.proxy` as a single line followed by `\n`.
/// - `user`     — first line of `.proxycredentials`.
/// - `password` — second line of `.proxycredentials`.
///
/// All fields are empty strings when no proxy is configured (the normal case).
/// Part of Phase 4/5 of the Swift 6.2 data model modernisation (#1287, #1299, #1300).
public struct RunnerProxyConfig: Sendable, Equatable {
    /// Raw proxy URL written to `.proxy` as a single line followed by `\n`.
    /// Empty string means no proxy is configured.
    public var url: String
    /// Proxy username, written as line 1 of `.proxycredentials`.
    public var user: String
    /// Proxy password, written as line 2 of `.proxycredentials`.
    public var password: String

    /// Creates a new `RunnerProxyConfig`.
    /// All parameters default to empty string, representing no proxy.
    public init(url: String = "", user: String = "", password: String = "") {
        self.url = url
        self.user = user
        self.password = password
    }

    /// `true` when no proxy fields are set — no files need to exist on disk.
    public var isEmpty: Bool { url.isEmpty && user.isEmpty && password.isEmpty }
}
