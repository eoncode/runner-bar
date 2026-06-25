// RunnerEditDraft+ProductionLoad.swift
// RunnerBar
//
// Moved from Sources/RunnerBar/Runner/RunnerEditDraft.swift (#1618).

// MARK: - Production convenience

/// Production-layer convenience shim for `RunnerEditDraft.load`.
///
/// Internal visibility is intentional: this shim is in the same module as
/// `RunnerEditDraft` and wires the production singletons. It must not be
/// part of the public API — exposing it would embed singleton coupling in
/// the Core library surface, undermining the protocol-DI design.
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
