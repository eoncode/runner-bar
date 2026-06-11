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
/// The store performs a typed decode via `RunnerConfig`, then writes the updated
/// value back using `JSONEncoder`. All caller-facing APIs are strongly typed and
/// `async`, which keeps runner config I/O out of view code and commit helpers.
public actor RunnerConfigStore {

    // MARK: Shared instance

    /// The shared singleton instance.
    public static let shared = RunnerConfigStore()

    // MARK: Private properties

    /// Decoder used for reading `.runner` JSON.
    private let decoder = JSONDecoder()
    /// Encoder used for writing `.runner` JSON (pretty-printed, sorted keys).
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    // MARK: Init

    /// Private initialiser — use `RunnerConfigStore.shared`.
    private init() {}

    // MARK: Public

    /// Loads the typed runner config from `installPath/.runner`.
    ///
    /// Handles the UTF-8 BOM prefix emitted by the GitHub runner agent.
    ///
    /// - Note: `Data(contentsOf:)` is synchronous and blocks the actor's thread
    ///   for the duration of the disk read. `.runner` files are small (< 1 KB) so
    ///   this is acceptable in practice. Phase 4/5 should migrate to
    ///   `FileHandle`+`AsyncBytes` or a `CheckedContinuation`+`DispatchQueue.global`
    ///   wrapper once `RunnerProxyStore` is introduced — tracked in #1316.
    public func load(at installPath: String) async throws -> RunnerConfig {
        let url = runnerConfigURL(for: installPath)
        var data = try Data(contentsOf: url)
        if data.prefix(3).elementsEqual([0xEF, 0xBB, 0xBF]) {
            data.removeFirst(3)
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
    /// Performs a read-modify-write merge so unknown agent-managed keys already
    /// present in `.runner` are preserved instead of being dropped on save.
    ///
    /// - Note: Both `Data(contentsOf:)` reads here are synchronous (see `load(at:)` note).
    public func save(_ config: RunnerConfig, at installPath: String) async throws {
        let url = runnerConfigURL(for: installPath)

        var raw: [String: Any] = [:]
        if let existingData = try? Data(contentsOf: url) {
            let data: Data
            if existingData.prefix(3).elementsEqual([0xEF, 0xBB, 0xBF]) {
                data = Data(existingData.dropFirst(3))
            } else {
                data = existingData
            }
            if let object = try? JSONSerialization.jsonObject(with: data),
               let dict = object as? [String: Any] {
                raw = dict
            }
        }

        raw[RunnerConfig.CodingKeys.workFolder.rawValue] = config.workFolder
        // Only write disableUpdate when it is explicitly set; omit the key when nil
        // to match the agent's own convention (key absent == false).
        if let disableUpdate = config.disableUpdate {
            raw[RunnerConfig.CodingKeys.disableUpdate.rawValue] = disableUpdate
        } else {
            raw.removeValue(forKey: RunnerConfig.CodingKeys.disableUpdate.rawValue)
        }
        // Write optional fields only when non-nil to avoid injecting "key": null
        // into the agent-managed file (JSONSerialization encodes Swift nil as NSNull).
        if let v = config.platform             { raw[RunnerConfig.CodingKeys.platform.rawValue] = v }
        if let v = config.platformArchitecture { raw[RunnerConfig.CodingKeys.platformArchitecture.rawValue] = v }
        if let v = config.agentVersion         { raw[RunnerConfig.CodingKeys.agentVersion.rawValue] = v }
        if let v = config.ephemeral            { raw[RunnerConfig.CodingKeys.ephemeral.rawValue] = v }
        if let v = config.agentId             { raw[RunnerConfig.CodingKeys.agentId.rawValue] = v }

        do {
            let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            log("RunnerConfigStore › save failed for \(url.path): \(error)")
            throw RunnerConfigStoreError.writeFailed(installPath, error)
        }
        log("RunnerConfigStore › saved config to \(url.path)")
    }

    // MARK: Private

    /// Returns the URL of the `.runner` file inside `installPath`.
    private func runnerConfigURL(for installPath: String) -> URL {
        URL(fileURLWithPath: installPath).appendingPathComponent(".runner")
    }
}
