// GitHubTokenCache.swift
// RunnerBar
//
// Re-export shim — githubToken() and invalidateTokenCache() have moved to RunnerBarCore.
// TODO: Delete this file once all call-sites in RunnerBar resolve these
// symbols via `import RunnerBarCore` directly.
import RunnerBarCore

// Free functions cannot be typealiased, but importing RunnerBarCore here
// re-exports githubToken() and invalidateTokenCache() into the RunnerBar
// module scope, keeping existing unqualified call-sites compiling unchanged.
// If RunnerBarCore removes these symbols, this file will fail to compile —
// which is the desired guard behaviour.
@_exported import RunnerBarCore
