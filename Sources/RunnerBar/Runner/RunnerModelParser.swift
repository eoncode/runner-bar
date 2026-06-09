// RunnerModelParser.swift
// RunnerBar
import Foundation

// MARK: - .runner JSON parser

/// Reads `installPath/.runner` JSON and builds a `RunnerModel`.
///
/// Handles UTF-8 BOM stripping (the GitHub Actions runner agent writes BOM-prefixed JSON)
/// and decodes the `RunnerJSON` envelope into a fully-constructed `RunnerModel`.
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
    let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    if data.prefix(3).elementsEqual(bom) {
        data = data.dropFirst(3)
        log("RunnerModelParser › runnerModelFromIndex — stripped UTF-8 BOM from '\(name)'")
    }

    let json = try? JSONDecoder().decode(RunnerJSON.self, from: data)
    if json == nil {
        log("RunnerModelParser › ⚠️ runnerModelFromIndex — JSON decode failed for '\(name)' at \(installPath). File may be malformed.")
    } else {
        log("RunnerModelParser › runnerModelFromIndex — '\(name)' agentId=\(String(describing: json?.agentId)) gitHubUrl=\(String(describing: json?.gitHubUrl))")
    }
    return RunnerModel(
        // Prefer the AgentName decoded from the .runner file; fall back to the index key
        // if the field is absent (older runner agent versions may omit it).
        runnerName: json?.runnerName ?? name,
        gitHubUrl: json?.gitHubUrl,
        agentId: json?.agentId,
        workFolder: json?.workFolder,
        installPath: installPath,
        isRunning: false,
        platform: json?.platform,
        platformArchitecture: json?.platformArchitecture,
        agentVersion: json?.agentVersion,
        isEphemeral: json?.ephemeral ?? false
    )
}

// MARK: - RunnerJSON

/// Decodable envelope for the `.runner` JSON file written by the GitHub Actions runner agent.
///
/// Used by both `runnerModelFromIndex` (store hydration) and `AddRunnerSheet` (pre-existing
/// runner import) so that both code paths decode from the same struct.
struct RunnerJSON: Decodable {
    /// The GitHub server URL associated with this runner (e.g. `https://github.com`).
    let gitHubUrl: String?
    /// The display name the runner registered with.
    /// Present in the `.runner` file as `AgentName`.
    let runnerName: String?
    /// The numeric agent identifier assigned by the GitHub Actions service.
    let agentId: Int?
    /// The working folder used by jobs executed on this runner.
    let workFolder: String?
    /// The OS platform string reported by the runner agent (e.g. `linux`, `darwin`).
    let platform: String?
    /// The CPU architecture string reported by the runner agent (e.g. `X64`, `ARM64`).
    let platformArchitecture: String?
    /// The version string of the runner agent binary.
    let agentVersion: String?
    /// Whether this runner is configured as ephemeral (single-job, then self-removes).
    let ephemeral: Bool?

    /// Maps Swift property names to the JSON keys used by the runner agent.
    /// Note: the agent uses PascalCase for most keys but camelCase for `gitHubUrl`.
    private enum CodingKeys: String, CodingKey {
        /// Maps to the camelCase `gitHubUrl` key in the agent JSON.
        case gitHubUrl
        /// Maps to the PascalCase `AgentName` key in the agent JSON.
        case runnerName           = "AgentName"
        /// Maps to the PascalCase `AgentId` key in the agent JSON.
        case agentId              = "AgentId"
        /// Maps to the PascalCase `WorkFolder` key in the agent JSON.
        case workFolder           = "WorkFolder"
        /// Maps to the PascalCase `Platform` key in the agent JSON.
        case platform             = "Platform"
        /// Maps to the PascalCase `PlatformArchitecture` key in the agent JSON.
        case platformArchitecture = "PlatformArchitecture"
        /// Maps to the PascalCase `AgentVersion` key in the agent JSON.
        case agentVersion         = "AgentVersion"
        /// Maps to the PascalCase `Ephemeral` key in the agent JSON.
        case ephemeral            = "Ephemeral"
    }
}
