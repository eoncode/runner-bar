// GitHubTokenCache.swift
// RunnerBar
//
// githubToken() and invalidateTokenCache() have moved to RunnerBarCore.
// They are re-exported into RunnerBar's module scope via the @_exported
// import below, so all existing unqualified call-sites continue to compile.
//
// TODO: Delete this file once confirmed that all callers resolve these
// symbols cleanly via RunnerBar/Exports.swift. Tracked for removal
// immediately post-merge.
@_exported import RunnerBarCore
