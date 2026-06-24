// RunnerPollerConformances.swift
// RunnerBar
//
// Step 10: Conformances moved here from the deleted RunnerStore.swift.
// These extensions live in the app target because they reference concrete
// app-layer types (AppPreferencesStore, ScopeStore) and their protocols
// are defined in RunnerBarCore.
import RunnerBarCore

/// Conforms `AppPreferencesStore` to `AppPreferencesStoreProtocol` so the live
/// singleton can be injected at the production call site without any wrapper.
extension AppPreferencesStore: AppPreferencesStoreProtocol {}

/// Conforms `ScopeStore` to `ScopeStoreProtocol` so the live singleton can be
/// injected at the production call site without any wrapper.
extension ScopeStore: ScopeStoreProtocol {}
