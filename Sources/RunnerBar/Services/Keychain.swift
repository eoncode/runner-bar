// Keychain.swift
// RunnerBar
//
// Re-export shim — Keychain has moved to RunnerBarCore.
// TODO: Delete this file once all call-sites in RunnerBar have been
// verified to resolve Keychain via `import RunnerBarCore` directly.
import RunnerBarCore

@available(*, deprecated, renamed: "RunnerBarCore.Keychain")
public typealias Keychain = RunnerBarCore.Keychain
