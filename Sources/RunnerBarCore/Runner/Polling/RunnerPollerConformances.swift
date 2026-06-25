// RunnerPollerConformances.swift
// RunnerBarCore
//
// Moved from Sources/RunnerBar/Runner/RunnerPollerConformances.swift (#1618).
// Both concrete types and both protocols are Core-resident; the conformances belong here.

/// Conforms `AppPreferencesStore` to `AppPreferencesStoreProtocol` so the live
/// singleton can be injected at the production call site without any wrapper.
extension AppPreferencesStore: AppPreferencesStoreProtocol {}

/// Conforms `ScopeStore` to `ScopeStoreProtocol` so the live singleton can be
/// injected at the production call site without any wrapper.
extension ScopeStore: ScopeStoreProtocol {}
