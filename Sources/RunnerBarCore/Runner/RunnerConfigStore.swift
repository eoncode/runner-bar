// RunnerConfigStore.swift
// RunnerBarCore
import Foundation

// MARK: - RunnerConfigStoreError

/// Errors thrown while reading or writing the runner `.runner` configuration file.
public enum RunnerConfigStoreError: LocalizedError {
    /// The `.runner` file could not be read from disk (missing, permissions, I/O error).
    case readFailed(String, any Error)
    /// The `.runner` file could not be decoded into `RunnerConfig`.
    case decodeFailed(String)
    /// The updated config could not be serialised or written to disk.
    case writeFailed(String, any Error)
    /// The existing `.runner` file is present but cannot be decoded during a save.
    ///
    /// Proceeding from an empty dict would silently drop agent-managed keys such as
    /// `jitConfig`, de-registering ephemeral JIT runners with no user-visible error.
    /// The caller must surface this error before attempting a write.
    case malformedExistingFile(String)

    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .readFailed(let installPath, let underlying):
            "Failed to read runner configuration at \(installPath)/.runner: \(underlying.localizedDescription)"
        case .decodeFailed(let installPath):
            "Failed to decode runner configuration at \(installPath)/.runner"
        case .writeFailed(let installPath, let underlying):
            "Failed to write runner configuration at \(installPath)/.runner: \(underlying.localizedDescription)"
        case .malformedExistingFile(let installPath):
            "Existing runner configuration at \(installPath)/.runner is malformed and cannot be safely overwritten — agent-managed keys would be lost"
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
/// Disk I/O is performed in `@concurrent` free functions so the actor's cooperative
/// thread is never blocked by synchronous file I/O. This replaces the previous
/// `DispatchQueue.global` + `withCheckedThrowingContinuation` bridge pattern and also
/// removes the `let config = copy config` workaround that was needed because a
/// `borrowing` parameter cannot escape into an `@escaping` closure.
///
/// **Error contract for `save(_:at:)`:** if the existing `.runner` file is present but
/// cannot be decoded (malformed JSON), `save()` throws `malformedExistingFile` rather
/// than proceeding from an empty dictionary — which would silently drop agent-managed
/// keys such as `jitConfig`. See `RunnerConfigStoreError.malformedExistingFile`.
/// `load(at:)` never throws `malformedExistingFile` — only `readFailed` / `decodeFailed`.
public actor RunnerConfigStore: RunnerConfigStoreProtocol {

    // MARK: Shared instance

    /// The shared singleton instance.
    public static let shared = RunnerConfigStore()

    // MARK: Private properties

    /// Decoder used for reading `.runner` JSON in `load(at:)`.
    /// `nonisolated` is required so `loadRunnerData(@concurrent)` — which runs outside
    /// the actor's serial executor — can capture this property without an actor hop.
    /// Thread-safety comes from `JSONDecoder`'s immutability after initialisation:
    /// Apple documents `JSONDecoder` as having no mutable state post-init, so concurrent
    /// reads from multiple `@concurrent` invocations are safe regardless of actor isolation.
    nonisolated private let decoder = JSONDecoder()

    // MARK: Init

    /// Private initialiser — use `RunnerConfigStore.shared`.
    private init() {
        // Singleton — intentionally empty; use `RunnerConfigStore.shared`.
    }

    // MARK: Public

    /// Loads the typed runner config from `installPath/.runner`.
    ///
    /// Handles the UTF-8 BOM prefix emitted by the GitHub runner agent.
    /// Disk I/O runs in a `@concurrent` free function so the actor's cooperative
    /// thread is never blocked.
    public func load(at installPath: String) async throws(RunnerConfigStoreError) -> RunnerConfig {
        let url = runnerConfigURL(for: installPath)
        let data: Data
        do {
            data = try await loadRunnerData(from: url, installPath: installPath)
        } catch let configError as RunnerConfigStoreError {
            throw configError
        } catch {
            throw RunnerConfigStoreError.readFailed(installPath, error)
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
    /// Disk I/O runs in a `@concurrent` free function so the actor's cooperative
    /// thread is never blocked. `config` can be `borrowing` here because a
    /// `borrowing` parameter does not escape into an `@escaping` closure — the
    /// previous `let config = copy config` workaround is no longer needed.
    public func save(_ config: borrowing RunnerConfig, at installPath: String) async throws(RunnerConfigStoreError) {
        let url = runnerConfigURL(for: installPath)
        do {
            try await saveRunnerConfig(config, to: url, installPath: installPath)
        } catch let configError as RunnerConfigStoreError {
            throw configError
        } catch {
            throw RunnerConfigStoreError.writeFailed(installPath, error)
        }
    }

    // MARK: Private

    /// Returns the URL of the `.runner` file inside `installPath`.
    private func runnerConfigURL(for installPath: String) -> URL {
        URL(fileURLWithPath: installPath).appendingPathComponent(".runner")
    }
}

// MARK: - @concurrent disk helpers

/// Reads and BOM-strips the `.runner` file at `url`.
///
/// Marked `async` so `@concurrent` can place it on the Swift cooperative thread
/// pool without blocking an actor's serial executor. The I/O itself is synchronous
/// inside the function body; `@concurrent` provides the off-actor scheduling.
/// Throws `RunnerConfigStoreError.readFailed` on any I/O error.
@concurrent
private func loadRunnerData(from url: URL, installPath: String) async throws -> Data {
    do {
        let raw = try Data(contentsOf: url)
        return stripRunnerConfigBOM(raw)
    } catch {
        throw RunnerConfigStoreError.readFailed(installPath, error)
    }
}

/// Performs the read-modify-write merge and writes the result to `url` atomically.
///
/// Marked `async` so `@concurrent` can place it on the Swift cooperative thread
/// pool without blocking an actor's serial executor.
///
/// A fresh `JSONDecoder` and `JSONEncoder` are created per call. Apple does not
/// document either type as safe for concurrent use on the same instance, and two
/// simultaneous `save()` calls can invoke this helper concurrently.
///
/// Throws `RunnerConfigStoreError.malformedExistingFile` if the existing `.runner`
/// file is present but cannot be decoded — proceeding from an empty dict would
/// silently drop agent-managed keys such as `jitConfig`.
@concurrent
private func saveRunnerConfig(
    _ config: RunnerConfig,
    to url: URL,
    installPath: String
) async throws {
    // Read-modify-write: load existing keys so agent-managed keys are preserved.
    let decoder = JSONDecoder()
    var raw: [String: AnyJSON] = [:]
    if let existingData = try? Data(contentsOf: url) {
        let data = stripRunnerConfigBOM(existingData)
        if let dict = try? decoder.decode([String: AnyJSON].self, from: data) {
            raw = dict
        } else {
            // Decode failed — the file is present but malformed. Proceeding
            // from an empty dict would silently drop agent-managed keys (e.g.
            // jitConfig), de-registering ephemeral JIT runners. Throw so the
            // caller can surface the error instead of silently corrupting state.
            log("RunnerConfigStore › save: existing .runner at \(url.path) is malformed; aborting save to protect agent-managed keys")
            throw RunnerConfigStoreError.malformedExistingFile(installPath)
        }
    } else {
        // File is missing (first registration) or temporarily unreadable (I/O error).
        // Writing from scratch is correct for a missing file. For a transiently
        // unreadable file, unknown agent-managed keys (e.g. jitConfig, gitHubUrl)
        // will be dropped — the malformed-content path above is now protected;
        // the I/O-failure path is tracked in #1499.
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
    if let val = config.platform { raw[RunnerConfig.CodingKeys.platform.rawValue] = .string(val) }
    if let val = config.platformArchitecture { raw[RunnerConfig.CodingKeys.platformArchitecture.rawValue] = .string(val) }
    if let val = config.agentVersion { raw[RunnerConfig.CodingKeys.agentVersion.rawValue] = .string(val) }
    if let val = config.ephemeral { raw[RunnerConfig.CodingKeys.ephemeral.rawValue] = .bool(val) }
    if let val = config.agentId { raw[RunnerConfig.CodingKeys.agentId.rawValue] = .int(val) }

    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(raw)
        try data.write(to: url, options: .atomic)
        log("RunnerConfigStore › saved config to \(url.path)")
    } catch {
        log("RunnerConfigStore › save failed for \(url.path): \(error)")
        throw RunnerConfigStoreError.writeFailed(installPath, error)
    }
}

/// Strips the UTF-8 BOM (`0xEF 0xBB 0xBF`) prefix from `data` if present.
///
/// Extracted as a file-scope free function so both `loadRunnerData` and
/// `saveRunnerConfig` can call it without synthesising `nonisolated` actor access.
/// The GitHub runner agent emits a UTF-8 BOM on some platforms; `JSONDecoder`
/// rejects the BOM, so it must be removed before decoding.
private func stripRunnerConfigBOM(_ data: Data) -> Data {
    data.prefix(3).elementsEqual([0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
}
