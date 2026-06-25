// RunnerEditDraft+ProductionLoad.swift
// RunnerBar
//
// Moved from Sources/RunnerBar/Runner/RunnerEditDraft.swift (#1618).

// MARK: - Production convenience

/// Production-layer convenience shim for `RunnerEditDraft.load`.
///
/// Bridges the protocol-typed Core API to the concrete shared store actors.
/// Call sites in the app target can use `draft.load(installPath:)` without
/// referencing `RunnerConfigStore` or `RunnerProxyStore` directly.
extension RunnerEditDraft {
    /// Loads disk state using the production `RunnerConfigStore.shared` and `RunnerProxyStore.shared`.
    @discardableResult
    public mutating func load(installPath: String) async -> RunnerConfig? {
        await load(
            installPath: installPath,
            configStore: RunnerConfigStore.shared,
            proxyStore: RunnerProxyStore.shared
        )
    }
}
