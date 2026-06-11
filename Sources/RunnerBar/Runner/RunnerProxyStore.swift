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

// MARK: - RunnerProxyStoreError

/// Errors thrown while writing proxy files.
public enum RunnerProxyStoreError: LocalizedError {
    /// One or more proxy files could not be written or removed.
    /// `messages` contains a human-readable description for each failing file.
    case writeFailed([String])

    /// A human-readable description of the error, suitable for display in alerts.
    public var errorDescription: String? {
        switch self {
        case .writeFailed(let messages):
            "Failed to write proxy files: " + messages.joined(separator: "; ")
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

    /// Use `RunnerProxyStore.shared` — direct instantiation is not permitted.
    private init() {}

    // MARK: - load(at:)

    /// Reads `.proxy` and `.proxycredentials` at `installPath`.
    ///
    /// This method is **non-throwing**: missing proxy files are the normal
    /// case (most runners have no proxy). A zeroed `RunnerProxyConfig` is
    /// returned whenever either or both files are absent.
    public func load(at installPath: String) async -> RunnerProxyConfig {
        let base     = URL(fileURLWithPath: installPath)
        let proxyURL = base.appendingPathComponent(".proxy")
        let credURL  = base.appendingPathComponent(".proxycredentials")

        let url: String = (try? String(contentsOf: proxyURL, encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""

        var user = ""
        var password = ""
        if let credContent = try? String(contentsOf: credURL, encoding: .utf8) {
            let lines = credContent.components(separatedBy: "\n")
            user     = lines.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            password = lines.indices.contains(1)
                ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
        }

        return RunnerProxyConfig(url: url, user: user, password: password)
    }

    // MARK: - save(_:at:)

    /// Writes (or removes) `.proxy` and `.proxycredentials` at `installPath`.
    ///
    /// Each file is handled independently so a failure on one does not mask
    /// a failure on the other. Both errors are logged; if either write fails
    /// `RunnerProxyStoreError.writeFailed` is thrown with all messages.
    ///
    /// - `.proxy` is written as `url + "\n"`, or removed when `config.url` is empty.
    /// - `.proxycredentials` is written as `user + "\n" + password + "\n"`,
    ///   or removed when both `config.user` and `config.password` are empty.
    public func save(_ config: RunnerProxyConfig, at installPath: String) async throws {
        let base     = URL(fileURLWithPath: installPath)
        let proxyURL = base.appendingPathComponent(".proxy")
        let credURL  = base.appendingPathComponent(".proxycredentials")

        var messages: [String] = []

        // .proxy
        do {
            if config.url.isEmpty {
                try removeIfPresent(at: proxyURL)
            } else {
                try (config.url + "\n").write(to: proxyURL, atomically: true, encoding: .utf8)
            }
        } catch {
            let msg = ".proxy write error: \(error)"
            log("RunnerProxyStore › \(msg)")
            messages.append(msg)
        }

        // .proxycredentials
        do {
            if config.user.isEmpty && config.password.isEmpty {
                try removeIfPresent(at: credURL)
            } else {
                let content = config.user + "\n" + config.password + "\n"
                try content.write(to: credURL, atomically: true, encoding: .utf8)
            }
        } catch {
            let msg = ".proxycredentials write error: \(error)"
            log("RunnerProxyStore › \(msg)")
            messages.append(msg)
        }

        if !messages.isEmpty {
            throw RunnerProxyStoreError.writeFailed(messages)
        }
    }

    // MARK: - Private helpers

    /// Removes the file at `url` if it exists, silently ignoring `NSFileNoSuchFileError`.
    /// Any other error is re-thrown so callers can distinguish a missing file
    /// (harmless) from a genuine I/O failure (permissions, locked volume, etc.).
    private func removeIfPresent(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            // File didn't exist — expected, not an error.
        }
    }
}
