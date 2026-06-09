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
        runnerName: name,
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
private struct RunnerJSON: Decodable {
    let gitHubUrl: String?
    let agentId: Int?
    let workFolder: String?
    let platform: String?
    let platformArchitecture: String?
    let agentVersion: String?
    let ephemeral: Bool?

    enum CodingKeys: String, CodingKey {
        case gitHubUrl            = "gitHubUrl"
        case agentId              = "AgentId"
        case workFolder           = "WorkFolder"
        case platform             = "Platform"
        case platformArchitecture = "PlatformArchitecture"
        case agentVersion         = "AgentVersion"
        case ephemeral            = "Ephemeral"
    }
}
