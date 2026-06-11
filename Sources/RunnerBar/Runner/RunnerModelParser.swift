// RunnerModelParser.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - .runner JSON parser

/// Reads `installPath/.runner` JSON and builds a `RunnerModel`.
///
/// Handles UTF-8 BOM stripping (the GitHub Actions runner agent writes BOM-prefixed JSON)
/// and decodes via `RunnerConfig` (typed) + `RunnerDiscoveryFields` (discovery-only fields).
///
/// `RunnerJSON` has been removed — `RunnerConfig` is the single typed path for all
/// `.runner` file access. Discovery-only fields (`gitHubUrl`, `AgentName`) are decoded
/// by the lightweight `RunnerDiscoveryFields` struct, which is local to this file.
///
/// - Parameters:
///   - name: The runner name used as the dedup key in `LocalRunnerIndex`.
///   - installPath: The absolute path to the runner's install directory.
/// - Returns: A hydrated `RunnerModel`, or `nil` if the `.runner` file is missing or malformed.
func runnerModelFromIndex(name: String, installPath: String) -> RunnerModel? {
    log("RunnerModelParser › runnerModelFromIndex — parsing '\(name)' at \(installPath)")
    let jsonURL = URL(fileURLWithPath: installPath).appendingPathComponent(".runner")
    guard var data = try? Data(contentsOf: jsonURL) else {
        log("RunnerModelParser › ⚠️ runnerModelFromIndex — no .runner file at \(installPath), skipping '\(name)'")
        return nil
    }

    // Strip UTF-8 BOM (0xEF 0xBB 0xBF) — runner agent writes BOM-prefixed JSON.
    // Note: RunnerConfigStore.load(at:) performs identical BOM stripping for the
    // edit/save path. This copy is intentional — runnerModelFromIndex is a sync
    // discovery function that reads its own Data directly and cannot use the async
    // store API. If BOM handling ever changes, update both sites. (#1298)
    let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    if data.prefix(3).elementsEqual(bom) {
        data = data.dropFirst(3)
        log("RunnerModelParser › runnerModelFromIndex — stripped UTF-8 BOM from '\(name)'")
    }

    let decoder = JSONDecoder()
    let config = try? decoder.decode(RunnerConfig.self, from: data)
    let discovery = try? decoder.decode(RunnerDiscoveryFields.self, from: data)

    if config == nil {
        log("RunnerModelParser › ⚠️ runnerModelFromIndex — RunnerConfig decode failed for '\(name)' at \(installPath). File may be malformed.")
    } else {
        log("RunnerModelParser › runnerModelFromIndex — '\(name)' agentId=\(String(describing: config?.agentId)) gitHubUrl=\(String(describing: discovery?.gitHubUrl))")
    }

    return RunnerModel(
        // Prefer the AgentName decoded from the .runner file; fall back to the index key
        // if the field is absent (older runner agent versions may omit it).
        runnerName: discovery?.runnerName ?? name,
        gitHubUrl: discovery?.gitHubUrl,
        agentId: config?.agentId,
        workFolder: config?.workFolder,
        installPath: installPath,
        isRunning: false,
        platform: config?.platform,
        platformArchitecture: config?.platformArchitecture,
        agentVersion: config?.agentVersion,
        isEphemeral: config?.ephemeral ?? false
    )
}

// MARK: - RunnerDiscoveryFields

/// Lightweight `Decodable` for the two `.runner` fields used only during discovery
/// that are not part of `RunnerConfig` (which covers the editable/persisted subset).
///
/// - `gitHubUrl` — the GitHub server URL the runner registered against.
/// - `runnerName` — the display name the runner registered with (`AgentName` in JSON).
///
/// All other fields are decoded via `RunnerConfig` directly.
private struct RunnerDiscoveryFields: Decodable {
    /// The GitHub server URL associated with this runner (e.g. `https://github.com`).
    let gitHubUrl: String?
    /// The display name the runner registered with (JSON key: `AgentName`).
    let runnerName: String?

    /// Maps the `.runner` / `.credentials` JSON keys to Swift property names.
    private enum CodingKeys: String, CodingKey {
        /// Maps to the `gitHubUrl` key in the `.credentials` JSON.
        case gitHubUrl
        /// Maps to the `AgentName` key in the `.runner` JSON (PascalCase — agent-written).
        case runnerName = "AgentName"
    }
}
