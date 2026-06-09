// RunnerStore+InstallPathMap.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - InstallPathMap

/// Install-path map construction for `RunnerStore`.
extension RunnerStore {
    /// Lookup maps built from the local runner list, used by `fetchAndEnrichRunners`.
    struct InstallPathMap {
        /// Maps "scope/runnerName" to installPath (exact scope-prefixed match).
        let byFullKey: [String: String]
        /// Maps "runnerName" to installPath (name-only fallback).
        let byName: [String: String]
        /// Maps agentId to installPath using the local `.runner` JSON AgentId (scope-agnostic).
        let byId: [Int: String]
        /// Maps apiId to installPath using the GitHub REST API runner id from the last enrichment cycle.
        ///
        /// For org runners the GitHub API assigns an `id` that differs from the local
        /// `.runner` JSON `AgentId`. This map is keyed on the API id so that metrics
        /// can be resolved for org runners even when `byId` misses.
        let byApiId: [Int: String]
    }

    /// Builds four lookup maps from the local runner list.
    func buildInstallPathMap(
        scopes: [String],
        localRunners: [RunnerModel]
    ) -> InstallPathMap {
        var byFullKey: [String: String] = [:]
        var byName: [String: String] = [:]
        var byId: [Int: String] = [:]
        var byApiId: [Int: String] = [:]
        for localRunner in localRunners {
            guard let path = localRunner.installPath else {
                log("RunnerStore › buildInstallPathMap — SKIP \(localRunner.runnerName): installPath is nil")
                continue
            }
            byName[localRunner.runnerName] = path
            if let agentId = localRunner.agentId {
                byId[agentId] = path
            } else {
                log("RunnerStore › buildInstallPathMap — \(localRunner.runnerName): agentId is nil (will rely on apiId/fullKey/name fallback)")
            }
            if let apiId = localRunner.apiId {
                byApiId[apiId] = path
            }
            for scope in scopes {
                byFullKey["\(scope)/\(localRunner.runnerName)"] = path
            }
        }
        log("RunnerStore › buildInstallPathMap — localRunners=\(localRunners.count) scopes=\(scopes) → fullKeys=\(byFullKey.keys.sorted()) nameKeys=\(byName.keys.sorted()) idKeys=\(byId.keys.sorted()) apiIdKeys=\(byApiId.keys.sorted())")
        if byFullKey.isEmpty && !localRunners.isEmpty {
            log("RunnerStore › ⚠️ buildInstallPathMap — fullKey map is EMPTY despite localRunners=\(localRunners.count). Scopes=\(scopes). Check scope string format alignment with localRunner names.")
        }
        if localRunners.isEmpty {
            log("RunnerStore › ⚠️ buildInstallPathMap — localRunners is EMPTY. All maps are empty. Busy runners will have no installPath this cycle.")
        }
        return InstallPathMap(byFullKey: byFullKey, byName: byName, byId: byId, byApiId: byApiId)
    }
}
