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
struct RunnerProxyConfig: Sendable, Equatable {
    /// Raw proxy URL written to `.proxy` as a single line followed by `\n`.
    /// Empty string means no proxy is configured.
    var url: String
    /// Proxy username, written as line 1 of `.proxycredentials`.
    var user: String
    /// Proxy password, written as line 2 of `.proxycredentials`.
    var password: String

    /// Creates a new `RunnerProxyConfig`.
    /// All parameters default to empty string, representing no proxy.
    init(url: String = "", user: String = "", password: String = "") {
        self.url = url
        self.user = user
        self.password = password
    }

    /// `true` when no proxy fields are set — no files need to exist on disk.
    var isEmpty: Bool { url.isEmpty && user.isEmpty && password.isEmpty }
}

// MARK: - RunnerProxyStoreError

/// Errors thrown while writing proxy files.
enum RunnerProxyStoreError: LocalizedError {
    /// One or more proxy files could not be written or removed.
    /// `messages` contains a human-readable description for each failing file.
    case writeFailed([String])

    /// A human-readable description of the error, suitable for display in alerts.
    var errorDescription: String? {
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
/// Disk operations are dispatched to a background `DispatchQueue` so the
/// actor's cooperative thread is never blocked by synchronous file I/O.
///
/// File format (unchanged from previous implementation):
/// - `.proxy`            — raw proxy URL followed by `"\n"`.
/// - `.proxycredentials` — `user + "\n" + password + "\n"`.
///
/// - Note: Part of Phase 4 of the Swift 6.2 data model modernisation (#1287, #1299).
actor RunnerProxyStore {

    // MARK: Shared instance

    /// The shared singleton instance.
    static let shared = RunnerProxyStore()

    // MARK: Init

    /// Use `RunnerProxyStore.shared` — direct instantiation is not permitted.
    private init() {}

    // MARK: - load(at:)

    /// Reads `.proxy` and `.proxycredentials` at `installPath` on a background thread.
    ///
    /// This method is **non-throwing**: missing proxy files are the normal
    /// case (most runners have no proxy). A zeroed `RunnerProxyConfig` is
    /// returned whenever either or both files are absent.
    func load(at installPath: String) async -> RunnerProxyConfig {
        let base     = URL(fileURLWithPath: installPath)
        let proxyURL = base.appendingPathComponent(".proxy")
        let credURL  = base.appendingPathComponent(".proxycredentials")

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // Trim only newlines here — `save` writes `value + "\n"` so we
                // strip exactly that. Using `.whitespacesAndNewlines` would also
                // strip intentional surrounding spaces from credentials.
                let url: String = (try? String(contentsOf: proxyURL, encoding: .utf8))
                    .map { $0.trimmingCharacters(in: .newlines) } ?? ""

                var user = ""
                var password = ""
                if let credContent = try? String(contentsOf: credURL, encoding: .utf8) {
                    let lines = credContent.components(separatedBy: "\n")
                    user     = lines.first.map { $0.trimmingCharacters(in: .newlines) } ?? ""
                    password = lines.indices.contains(1)
                        ? lines[1].trimmingCharacters(in: .newlines)
                        : ""
                }

                continuation.resume(returning: RunnerProxyConfig(url: url, user: user, password: password))
            }
        }
    }

    // MARK: - save(_:at:)

    /// Writes (or removes) `.proxy` and `.proxycredentials` at `installPath`
    /// on a background thread.
    ///
    /// Each file is handled independently so a failure on one does not mask
    /// a failure on the other. Both errors are logged; if either write fails
    /// `RunnerProxyStoreError.writeFailed` is thrown with all messages.
    ///
    /// - `.proxy` is written as `url + "\n"`, or removed when `config.url` is empty.
    /// - `.proxycredentials` is written as `user + "\n" + password + "\n"`,
    ///   or removed when both `config.user` and `config.password` are empty.
    /// - Note: All three fields are trimmed of leading/trailing whitespace before
    ///   writing. This is intentional and matches `load(at:)`'s read behaviour,
    ///   ensuring a round-trip through load → save is idempotent. Callers should
    ///   not rely on preserving surrounding whitespace in proxy credentials.
    func save(_ config: RunnerProxyConfig, at installPath: String) async throws {
        // Fast path: nothing to write or remove when all fields are empty.
        // This also avoids spawning a background task for zero-config runners.
        guard !config.isEmpty else { return }

        let base     = URL(fileURLWithPath: installPath)
        let proxyURL = base.appendingPathComponent(".proxy")
        let credURL  = base.appendingPathComponent(".proxycredentials")

        // Trim defensively here so no call site can accidentally write whitespace to disk.
        let url      = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let user     = config.user.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = config.password.trimmingCharacters(in: .whitespacesAndNewlines)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .utility).async {
                var messages: [String] = []

                // .proxy
                do {
                    if url.isEmpty {
                        try Self.removeIfPresent(at: proxyURL)
                    } else {
                        try (url + "\n").write(to: proxyURL, atomically: true, encoding: .utf8)
                    }
                } catch {
                    let msg = ".proxy write error: \(error)"
                    log("RunnerProxyStore › \(msg)")
                    messages.append(msg)
                }

                // .proxycredentials
                do {
                    if user.isEmpty && password.isEmpty {
                        try Self.removeIfPresent(at: credURL)
                    } else {
                        let content = user + "\n" + password + "\n"
                        try content.write(to: credURL, atomically: true, encoding: .utf8)
                    }
                } catch {
                    let msg = ".proxycredentials write error: \(error)"
                    log("RunnerProxyStore › \(msg)")
                    messages.append(msg)
                }

                if messages.isEmpty {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: RunnerProxyStoreError.writeFailed(messages))
                }
            }
        }
    }

    // MARK: - Private helpers

    /// Removes the file at `url` if it exists, silently ignoring `NSFileNoSuchFileError`.
    /// Any other error is re-thrown so callers can distinguish a missing file
    /// (harmless) from a genuine I/O failure (permissions, locked volume, etc.).
    private static func removeIfPresent(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            // File didn't exist — expected, not an error.
        }
    }
}
