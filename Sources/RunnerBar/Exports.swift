// Exports.swift
// RunnerBar
//
// Re-exports the entire RunnerBarCore public API through the RunnerBar module.
// This means consumers of RunnerBar (views, app delegate, services) do not need
// to import RunnerBarCore explicitly — they get it transitively.
//
// ⚠️ Intentional design decision: all of RunnerBarCore's public surface becomes
// visible to any target that imports RunnerBar. Do not add types to RunnerBarCore
// that should remain private to the core module without also restricting them here.
@_exported import RunnerBarCore
