// RunnerProxyStore.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - RunnerProxyStore

/// Actor that owns all disk read/write for runner proxy configuration files.
///
/// Conforms to `RunnerProxyStoreProtocol` so it can be replaced with a test double
/// when injected into `SaveRunnerEditsUseCase`.
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
actor RunnerProxyStore: RunnerProxyStoreProtocol {

    // MARK: Shared instance

    /// The shared singleton instance.
    static let shared = RunnerProxyStore()

    // MARK: Init

    /// Use `RunnerProxyStore.shared` — direct instantiation is not permitted.
    private init() { /* singleton — use RunnerProxyStore.shared */ }

    // MARK: - load(at:)

    /// Reads `.proxy` and `.proxycredentials` at `installPath`.
    ///
    /// Disk I/O runs in a `@concurrent` free function so the actor's cooperative
    /// thread is never blocked. Non-throwing: missing files return a zeroed config.
    func load(at installPath: String) async -> RunnerProxyConfig {
        let base = URL(fileURLWithPath: installPath)
        return await loadProxyFiles(
            proxyURL: base.appendingPathComponent(".proxy"),
            credURL:  base.appendingPathComponent(".proxycredentials")
        )
    }

    // MARK: - save(_:at:)

    /// Writes (or removes) `.proxy` and `.proxycredentials` at `installPath`.
    ///
    /// Disk I/O runs in a `@concurrent` free function so the actor's cooperative
    /// thread is never blocked. Trimming and file operations happen entirely
    /// inside the `@concurrent` helper.
    ///
    /// Each file is handled independently so a failure on one does not mask
    /// a failure on the other. If either write fails,
    /// `RunnerProxyStoreError.writeFailed` is thrown with all accumulated messages.
    func save(_ config: RunnerProxyConfig, at installPath: String) async throws(RunnerProxyStoreError) {
        let base = URL(fileURLWithPath: installPath)
        do {
            try await saveProxyFiles(
                config,
                proxyURL: base.appendingPathComponent(".proxy"),
                credURL:  base.appendingPathComponent(".proxycredentials")
            )
        } catch let proxyError as RunnerProxyStoreError {
            throw proxyError
        } catch {
            // Defensive bridge: saveProxyFiles only throws RunnerProxyStoreError,
            // but typed-throw bridging through `any Error` requires this catch.
            throw RunnerProxyStoreError.writeFailed([error.localizedDescription])
        }
    }

    // MARK: - Private helpers

    /// Parses the raw credential file content into `user` and `password` components.
    ///
    /// Expects the first line to be the username and the second line (if present)
    /// to be the password. Missing lines yield empty strings.
    ///
    /// Trims `.whitespacesAndNewlines` (not just `.newlines`) so that files written
    /// with `\r\n` line endings (e.g. by Windows-based credential tools) do not leave
    /// a trailing `\r` on each component — which would silently break proxy authentication.
    private static func parseCredentialLines(_ content: String) -> (user: String, password: String) {
        let lines = content.components(separatedBy: "\n")
        let user = lines.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let credential = lines.indices.contains(1) ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (user, credential)
    }

    /// Writes the proxy URL to `destination` as `url + "\n"`, or removes the file if `url` is empty.
    private static func writeProxyURL(_ url: String, to destination: URL) throws {
        if url.isEmpty {
            try removeIfPresent(at: destination)
        } else {
            try (url + "\n").write(to: destination, atomically: true, encoding: .utf8)
        }
    }

    /// Writes the proxy credentials to `destination` as `user + "\n" + secret + "\n"`,
    /// or removes the file when both values are empty.
    private static func writeProxyCredentials(user: String, secret: String, to destination: URL) throws {
        if user.isEmpty && secret.isEmpty {
            try removeIfPresent(at: destination)
        } else {
            try (user + "\n" + secret + "\n").write(to: destination, atomically: true, encoding: .utf8)
        }
    }

    /// Removes the file at `url` if it exists; silently ignores `NSFileNoSuchFileError`.
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
