// Auth.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - Token cache
//
// githubToken() is called on every API request, often concurrently from multiple
// background threads. Without caching, each call spawns 1-2 shell subprocesses
// (security + gh auth token), flooding the log and wasting threads.
//
// The cache is populated on first successful resolution and cleared by:
//   - OAuthService.signOut() via invalidateTokenCache()
//   - Keychain.save()         via invalidateTokenCache()
//
// Thread-safety: read/write guarded by tokenCacheLock (OSAllocatedUnfairLock).

import os

/// Lock-protected in-memory cache for the resolved GitHub token.
private let tokenCacheLock = OSAllocatedUnfairLock(initialState: Optional<String>.none)

/// Clears the in-memory token cache. Call after saving a new token to Keychain
/// or after signing out so the next githubToken() call re-resolves from source.
func invalidateTokenCache() {
    tokenCacheLock.withLock { $0 = nil }
    log("Auth › token cache invalidated")
}

/// Returns a GitHub personal access token from the first available source.
///
/// Priority order:
/// 1. In-memory cache — avoids repeated shell spawns; invalidated on sign-in/sign-out.
/// 2. Keychain — OAuth token stored by OAuthService after the user signs in via the native flow.
/// 3. `gh auth token` — fallback for existing users who authenticated via the gh CLI.
///    Keeps working zero-friction during and after the transition to native OAuth.
/// 4. `GH_TOKEN` environment variable — useful in CI or scripted contexts.
/// 5. `GITHUB_TOKEN` environment variable — fallback for Actions-style environments.
///
/// Returns `nil` if no token is available from any source.
func githubToken() -> String? {
    // 1. In-memory cache
    if let cached = tokenCacheLock.withLock({ $0 }) { return cached }
    // 2. Keychain — preferred; set by OAuthService after native OAuth sign-in
    if let token = Keychain.token {
        tokenCacheLock.withLock { $0 = token }
        return token
    }
    // 3. gh CLI fallback — existing users keep working without re-authenticating
    if let ghPath = ghBinaryPath() {
        let result = shell("\(ghPath) auth token", timeout: 10)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.isEmpty && !result.hasPrefix("error") {
            tokenCacheLock.withLock { $0 = result }
            return result
        }
    }
    // 4–5. CI / environment variable fallbacks
    for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
        if let token = ProcessInfo.processInfo.environment[key], !token.isEmpty {
            tokenCacheLock.withLock { $0 = token }
            return token
        }
    }
    return nil
}
