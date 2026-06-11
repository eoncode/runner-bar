// RunnerEditDraft.swift
// RunnerBar
// Re-exported from RunnerBarCore. This stub keeps the file present so
// any in-progress local edits referencing this path still compile;
// the real type now lives in Sources/RunnerBarCore/Runner/RunnerEditDraft.swift.
import Foundation
import RunnerBarCore

// Convenience extension: production call site uses the concrete shared singletons
// so views don't need to import RunnerBarCore actors directly.
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
