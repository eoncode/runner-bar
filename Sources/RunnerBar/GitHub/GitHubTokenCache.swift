// GitHubTokenCache.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - Token cache
//
// githubToken() is called on every API request, often concurrently from multiple
// background threads. Without caching, each call reads from Keychain or the
// environment on every invocation, which adds unnecessary overhead.
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
    log("GitHubTokenCache › invalidateTokenCache — cache cleared")
}

/// Returns a GitHub personal access token from the first available source.
///
/// Priority order:
/// 1. In-memory cache — avoids repeated Keychain reads; invalidated on sign-in/sign-out.
/// 2. Keychain — OAuth token stored by OAuthService after the user signs in via the native flow.
/// 3. `GH_TOKEN` environment variable — useful in CI or scripted contexts.
/// 4. `GITHUB_TOKEN` environment variable — fallback for Actions-style environments.
///
/// Returns `nil` if no token is available from any source.
func githubToken() -> String? {
    // 1. In-memory cache
    if let cached = tokenCacheLock.withLock({ $0 }) {
        #if DEBUG
        log("GitHubTokenCache › githubToken — resolved from cache (len=\(cached.count))")
        #endif
        return cached
    }
    // 2. Keychain — preferred; set by OAuthService after native OAuth sign-in
    if let token = Keychain.token {
        #if DEBUG
        log("GitHubTokenCache › githubToken — resolved from Keychain (len=\(token.count)), populating cache")
        #endif
        tokenCacheLock.withLock { $0 = token }
        return token
    }
    #if DEBUG
    log("GitHubTokenCache › githubToken — Keychain: nil")
    #endif
    // 3–4. CI / environment variable fallbacks
    for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
        if let token = ProcessInfo.processInfo.environment[key], !token.isEmpty {
            #if DEBUG
            log("GitHubTokenCache › githubToken — resolved from env var \(key) (len=\(token.count)), populating cache")
            #endif
            tokenCacheLock.withLock { $0 = token }
            return token
        } else {
            #if DEBUG
            log("GitHubTokenCache › githubToken — env var \(key): nil/empty")
            #endif
        }
    }
    #if DEBUG
    log("GitHubTokenCache › githubToken — returning nil (no token from any source)")
    #endif
    return nil
}
