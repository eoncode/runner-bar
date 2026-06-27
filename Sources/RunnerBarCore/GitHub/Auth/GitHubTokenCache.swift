// GitHubTokenCache.swift
// RunnerBarCore
import Foundation
import Synchronization

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
// Thread-safety (P16 + Reach Goal P13): read/write guarded by tokenCache
// (Synchronization.Mutex). An actor wrapper was considered but rejected: it
// would require all call-sites to become async. Mutex provides native Swift 6.2
// mutual exclusion with synchronous semantics, which is correct here because
// the critical section is a single pointer swap — no suspension point needed.

/// Mutex-protected in-memory cache for the resolved GitHub token.
private let tokenCache = Mutex<String?>(nil)

/// Clears the in-memory token cache. Call after saving a new token to Keychain
/// or after signing out so the next githubToken() call re-resolves from source.
///
/// ### Namespacing rationale
/// `invalidateTokenCache()` and `githubToken()` are intentionally free functions
/// rather than members of a namespace type. They are called as unqualified
/// symbols from `Keychain.swift`, `OAuthService`, and SwiftUI views. Moving them
/// into a `KeychainTokenCache` enum would require updating ~6 call-sites across
/// 4 files for no correctness benefit. The module boundary (`RunnerBarCore`)
/// already provides the necessary scoping.
public func invalidateTokenCache() {
    tokenCache.withLock { $0 = nil }
    log("GitHubTokenCache › invalidateTokenCache — cache cleared", category: .transport)
}

// MARK: - Resolution helpers (SW-R1002: extracted to reduce cyclomatic complexity)

/// Returns the cached token if one has already been resolved, else `nil`.
private func resolveFromCache() -> String? {
    let cached = tokenCache.withLock { $0 }
    #if DEBUG
    if let cached {
        log("GitHubTokenCache › githubToken — resolved from cache (len=\(cached.count))", category: .transport)
    }
    #endif
    return cached
}

/// Reads the OAuth token from Keychain and populates the in-memory cache.
///
/// Thundering-herd on cold-start: two concurrent callers can both miss the
/// cache check and both reach here. Both reads are idempotent Keychain reads
/// returning the same value. The compare-before-write eliminates the redundant
/// second store, and the window only exists on first resolution (after that
/// every caller hits the cache in `resolveFromCache()`).
private func resolveFromKeychain() -> String? {
    guard let token = Keychain.token else {
        #if DEBUG
        log("GitHubTokenCache › githubToken — Keychain: nil", category: .transport)
        #endif
        return nil
    }
    #if DEBUG
    log("GitHubTokenCache › githubToken — resolved from Keychain (len=\(token.count)), populating cache", category: .transport)
    #endif
    tokenCache.withLock { if $0 == nil { $0 = token } }
    return token
}

/// Checks `GH_TOKEN` then `GITHUB_TOKEN` environment variables.
/// Populates the in-memory cache on first match.
private func resolveFromEnvironment() -> String? {
    for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
        if let token = ProcessInfo.processInfo.environment[key], !token.isEmpty {
            #if DEBUG
            log("GitHubTokenCache › githubToken — resolved from env var \(key) (len=\(token.count)), populating cache", category: .transport)
            #endif
            tokenCache.withLock { if $0 == nil { $0 = token } }
            return token
        }
        #if DEBUG
        log("GitHubTokenCache › githubToken — env var \(key): nil/empty", category: .transport)
        #endif
    }
    return nil
}

// MARK: - Public API

/// Returns a GitHub personal access token from the first available source.
///
/// Priority order:
/// 1. In-memory cache — avoids repeated Keychain reads; invalidated on sign-in/sign-out.
/// 2. Keychain — OAuth token stored by OAuthService after the user signs in via the native flow.
/// 3. `GH_TOKEN` environment variable — useful in CI or scripted contexts.
/// 4. `GITHUB_TOKEN` environment variable — fallback for Actions-style environments.
///
/// Returns `nil` if no token is available from any source.
public func githubToken() -> String? {
    if let token = resolveFromCache() { return token }
    if let token = resolveFromKeychain() { return token }
    if let token = resolveFromEnvironment() { return token }
    #if DEBUG
    log("GitHubTokenCache › githubToken — returning nil (no token from any source)", category: .transport)
    #endif
    return nil
}
