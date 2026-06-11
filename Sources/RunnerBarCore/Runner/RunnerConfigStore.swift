// RunnerConfigStore.swift
// RunnerBarCore
import Foundation

// MARK: - RunnerConfigStoreError

/// Errors thrown while reading or writing the runner `.runner` configuration file.
public enum RunnerConfigStoreError: LocalizedError {
    /// The `.runner` file could not be decoded into `RunnerConfig`.
    case decodeFailed(String)

    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .decodeFailed(let installPath):
            "Failed to decode runner configuration at \(installPath)/.runner"
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
    public func save(_ config: RunnerConfig, at installPath: String) async throws {
        let url = runnerConfigURL(for: installPath)
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
        log("RunnerConfigStore › saved config to \(url.path)")
    }

    // MARK: Private

    /// Returns the URL of the `.runner` file inside `installPath`.
    private func runnerConfigURL(for installPath: String) -> URL {
        URL(fileURLWithPath: installPath).appendingPathComponent(".runner")
    }
}
