// RunnerProxyStore.swift
// RunnerBar
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
/// Part of Phase 4 of the Swift 6.2 data model modernisation (#1287, #1299).
public struct RunnerProxyConfig: Sendable, Equatable {
    public var url: String
    public var user: String
    public var password: String

    public init(url: String = "", user: String = "", password: String = "") {
        self.url = url
        self.user = user
        self.password = password
    }

    /// `true` when no proxy fields are set — no files need to exist on disk.
    public var isEmpty: Bool { url.isEmpty && user.isEmpty && password.isEmpty }
}

// MARK: - RunnerProxyStoreError

/// Errors thrown while writing proxy files.
public enum RunnerProxyStoreError: LocalizedError {
    /// A proxy file could not be written or removed.
    case writeFailed(String, any Error)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let path, let underlying):
            "Failed to write proxy files at \(path): \(underlying.localizedDescription)"
        }
    }
}

// MARK: - RunnerProxyStore

/// Actor that owns all disk read/write for runner proxy configuration files.
///
/// Replaces the `loadProxy` private helper in `RunnerEditDraft` and the
/// `writeProxyFiles` / `removeIfPresent` free functions in `CommitRunnerEdit`.
///
/// File format (unchanged from previous implementation):
/// - `.proxy`            — raw proxy URL followed by `"\n"`.
/// - `.proxycredentials` — `user + "\n" + password + "\n"`.
///
/// - Note: Part of Phase 4 of the Swift 6.2 data model modernisation (#1287, #1299).
public actor RunnerProxyStore {

    // MARK: Shared instance

    /// The shared singleton instance.
    public static let shared = RunnerProxyStore()

    // MARK: Init

    private init() {}

    // MARK: Public

    /// Loads proxy configuration from `installPath/.proxy` and
    /// `installPath/.proxycredentials`.
    ///
    /// Returns a zero-value `RunnerProxyConfig` when neither file exists
    /// (the normal case for runners without a proxy).
    public func load(at installPath: String) async -> RunnerProxyConfig {
        // TODO (#1299): implement
        // - Read .proxy — single line, trim newline → url
        // - Read .proxycredentials — line 1 → user, line 2 → password
        // - Return zeroed config if files are absent (not an error)
        fatalError("RunnerProxyStore.load(at:) not yet implemented — Phase 4 (#1299)")
    }

    /// Saves proxy configuration to `installPath/.proxy` and
    /// `installPath/.proxycredentials`.
    ///
    /// Rules:
    /// - `.proxy` is written when `config.url` is non-empty; removed otherwise.
    /// - `.proxycredentials` is written when either `user` or `password` is
    ///   non-empty; removed otherwise.
    /// - Files are written atomically.
    /// - `NSFileNoSuchFileError` during removal is silently ignored.
    ///
    /// - Throws: `RunnerProxyStoreError.writeFailed` if any write or removal fails.
    public func save(_ config: RunnerProxyConfig, at installPath: String) async throws {
        // TODO (#1299): implement
        // - Move writeProxyFiles + removeIfPresent logic from CommitRunnerEdit here
        // - Both errors must be accumulated (a proxy-file failure ≠ a cred-file failure)
        fatalError("RunnerProxyStore.save(_:at:) not yet implemented — Phase 4 (#1299)")
    }

    // MARK: Private

    /// Removes the file at `url` if it exists, silently ignoring `NSFileNoSuchFileError`.
    /// Any other error is re-thrown so `save(_:at:)` can report it accurately.
    private func removeIfPresent(at url: URL) throws {
        // TODO (#1299): move implementation from CommitRunnerEdit.removeIfPresent
        fatalError("RunnerProxyStore.removeIfPresent(at:) not yet implemented — Phase 4 (#1299)")
    }
}
