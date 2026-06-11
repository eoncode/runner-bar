// RunnerEditDraft.swift
// RunnerBar
// `RunnerEditDraft` lives in RunnerBarCore (Sources/RunnerBarCore/Runner/RunnerEditDraft.swift).
// This file adds a production convenience extension so call sites in the app target
// can call load(installPath:) without importing or naming the shared store actors directly.
// This is a permanent part of the app-layer API, not a migration artifact.
import Foundation
import RunnerBarCore

// MARK: - Production convenience

/// Production-layer convenience shim for `RunnerEditDraft.load`.
///
/// Bridges the protocol-typed Core API to the concrete shared actors available
/// only in the `RunnerBar` app target. Call sites in the app can use
/// `draft.load(installPath:)` without referencing `RunnerConfigStore` or
/// `RunnerProxyStore` directly.
extension RunnerEditDraft {
    /// Loads disk state using the production `RunnerConfigStore.shared` and `RunnerProxyStore.shared`.
    @discardableResult
    mutating func load(installPath: String) async -> RunnerConfig? {
        await load(
            installPath: installPath,
            configStore: RunnerConfigStore.shared,
            proxyStore: RunnerProxyStore.shared
        )
    }
}
