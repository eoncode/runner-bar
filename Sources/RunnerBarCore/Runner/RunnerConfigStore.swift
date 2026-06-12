// RunnerConfigStore.swift
// RunnerBarCore
import Foundation

// MARK: - RunnerConfigStoreError

/// Errors thrown while reading or writing the runner `.runner` configuration file.
public enum RunnerConfigStoreError: LocalizedError {
    /// The `.runner` file could not be decoded into `RunnerConfig`.
    case decodeFailed(String)
    /// The updated config could not be serialised or written to disk.
    case writeFailed(String, any Error)

    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .decodeFailed(let installPath):
            "Failed to decode runner configuration at \(installPath)/.runner"
        case .writeFailed(let installPath, let underlying):
            "Failed to write runner configuration at \(installPath)/.runner: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - RunnerConfigStore

/// Actor that owns all disk read/write for runner `.runner` configuration files.
///
/// The store performs a typed decode via `RunnerConfig` for reads. For writes it uses
/// a read-modify-write merge via `AnyJSON` to preserve agent-managed keys not modelled
/// by `RunnerConfig`. All caller-facing APIs are strongly typed and `async`, which keeps
/// runner config I/O out of view code and commit helpers.
///
/// All disk operations are dispatched to `DispatchQueue.global(qos: .utility)` via
/// `withCheckedContinuation` / `withCheckedThrowingContinuation` so the actor's
/// cooperative thread is never blocked by synchronous file I/O — consistent with
/// the pattern used in `RunnerProxyStore`.
public actor RunnerConfigStore: RunnerConfigStoreProtocol {

    // MARK: Shared instance

    /// The shared singleton instance.
    public static let shared = RunnerConfigStore()

    // MARK: Private properties

    /// Decoder used for reading `.runner` JSON. Thread-safe: `JSONDecoder` has no mutable state after init.
    /// `nonisolated` so the DispatchQueue.global closure in `save(_:at:)` can capture
    /// it without crossing the actor's isolation boundary. Safe because `JSONDecoder`
    /// is immutable after initialisation and has no mutable state.
    nonisolated private let decoder = JSONDecoder()

    // MARK: Init

    /// Private initialiser — use `RunnerConfigStore.shared`.
    private init() {}

    // MARK: Private helpers

    /// Strips the UTF-8 BOM (`0xEF 0xBB 0xBF`) from `data` if present.
    ///
    /// The GitHub runner agent emits a UTF-8 BOM at the start of `.runner` files on some
    /// platforms. `JSONDecoder` rejects the BOM, so it must be removed before decoding.
    private static func stripBOM(from data: Data) -> Data {
        data.prefix(3).elementsEqual([0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
    }

    // MARK: Public

    /// Loads the typed runner config from `installPath/.runner`.
    ///
    /// Handles the UTF-8 BOM prefix emitted by the GitHub runner agent.
    /// Disk I/O is dispatched to `DispatchQueue.global(qos: .utility)` so the
    /// actor's cooperative thread is never blocked.
    public func load(at installPath: String) async throws -> RunnerConfig {
        let url = runnerConfigURL(for: installPath)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let raw = Self.stripBOM(from: try Data(contentsOf: url))
                    continuation.resume(returning: raw)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        do {
            return try decoder.decode(RunnerConfig.self, from: data)
        } catch {
            log("RunnerConfigStore › load failed for \(url.path): \(error)")
            throw RunnerConfigStoreError.decodeFailed(installPath)
        }
    }

    /// Saves the typed runner config to `installPath/.runner`.
    ///
    /// Uses a **read-modify-write merge** strategy:
    /// 1. The existing `.runner` file is decoded into a `[String: AnyJSON]` dictionary.
    /// 2. Only the fields covered by `RunnerConfig` are overwritten in that dictionary.
    /// 3. The merged dictionary is encoded and written back atomically.
    ///
    /// Agent-managed keys not modelled by `RunnerConfig` (e.g. `jitConfig`, `gitHubUrl`)
    /// are preserved via the private `AnyJSON` type — no `[String: Any]` or
    /// `JSONSerialization` is used anywhere in the merge path.
    ///
    /// Disk I/O is dispatched to `DispatchQueue.global(qos: .utility)` so the actor's
    /// cooperative thread is never blocked.
    public func save(_ config: RunnerConfig, at installPath: String) async throws {
        let url = runnerConfigURL(for: installPath)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                // Read-modify-write: load existing keys so agent-managed keys are preserved.
                var raw: [String: AnyJSON] = [:]
                if let existingData = try? Data(contentsOf: url) {
                    let data = Self.stripBOM(from: existingData)
                    if let dict = try? self.decoder.decode([String: AnyJSON].self, from: data) {
                        raw = dict
                    } else {
                        // Decode failed — existing file is malformed. Proceeding
                        // from an empty dict will drop unknown agent-managed keys on this save.
                        log("RunnerConfigStore › save: existing .runner at \(url.path) could not be parsed; unknown keys will not be preserved")
                    }
                } else {
                    // File is missing or temporarily unreadable. Writing from scratch.
                    // If the file exists but was unreadable, unknown agent-managed keys (e.g.
                    // jitConfig, gitHubUrl) will be dropped — tracked in a follow-up issue (TBD).
                    log("RunnerConfigStore › save: could not read existing .runner at \(url.path); writing from scratch")
                }

                // Always write workFolder so the user can clear a custom path back to the
                // agent default. An empty string is normalised to "_work" here — identical
                // to the value the agent writes on a fresh registration — so a load-failure
                // zero value and an intentional clear are both safe to round-trip.
                let workFolderValue = config.workFolder.isEmpty ? "_work" : config.workFolder
                raw[RunnerConfig.CodingKeys.workFolder.rawValue] = .string(workFolderValue)
                // Only write disableUpdate when it is explicitly set; omit the key when nil
                // to match the agent's own convention (key absent == false).
                if let disableUpdate = config.disableUpdate {
                    raw[RunnerConfig.CodingKeys.disableUpdate.rawValue] = .bool(disableUpdate)
                } else {
                    raw.removeValue(forKey: RunnerConfig.CodingKeys.disableUpdate.rawValue)
                }
                // Write optional fields only when non-nil to avoid injecting "key": null
                // into the agent-managed file.
                if let v = config.platform             { raw[RunnerConfig.CodingKeys.platform.rawValue]             = .string(v) }
                if let v = config.platformArchitecture { raw[RunnerConfig.CodingKeys.platformArchitecture.rawValue] = .string(v) }
                if let v = config.agentVersion         { raw[RunnerConfig.CodingKeys.agentVersion.rawValue]         = .string(v) }
                if let v = config.ephemeral            { raw[RunnerConfig.CodingKeys.ephemeral.rawValue]            = .bool(v)   }
                if let v = config.agentId              { raw[RunnerConfig.CodingKeys.agentId.rawValue]              = .int(v)    }

                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(raw)
                    try data.write(to: url, options: .atomic)
                    log("RunnerConfigStore › saved config to \(url.path)")
                    continuation.resume()
                } catch {
                    log("RunnerConfigStore › save failed for \(url.path): \(error)")
                    continuation.resume(throwing: RunnerConfigStoreError.writeFailed(installPath, error))
                }
            }
        }
    }

    // MARK: Private

    /// Returns the URL of the `.runner` file inside `installPath`.
    private func runnerConfigURL(for installPath: String) -> URL {
        URL(fileURLWithPath: installPath).appendingPathComponent(".runner")
    }
}
