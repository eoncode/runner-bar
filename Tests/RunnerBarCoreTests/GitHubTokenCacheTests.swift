// GitHubTokenCacheTests.swift
// RunnerBarCoreTests
//
// ⚠️ ISOLATION REQUIREMENT
// tokenCache is a process-global Mutex(nil) at module scope. Every test that
// calls githubToken() must call invalidateTokenCache() before returning so that
// cache state does not bleed across cases. This is enforced via `defer` at the
// top of each test body below.
//
// The suite is marked .serialized because tokenCache is process-global: parallel
// execution would allow one test's invalidateTokenCache() defer to race with
// another test's githubToken() call, producing non-deterministic results.
//
// Keychain is never touched: token resolution is exercised through environment
// variables only (GH_TOKEN / GITHUB_TOKEN), keeping these tests sandboxing-free
// and safe to run with `swift test`.
//
// CI note: GitHub Actions always injects GITHUB_TOKEN into the environment.
// Every test that asserts a nil return must strip BOTH env vars explicitly.

import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - Helpers

/// Saves and clears both token env vars, runs body, then restores originals.
/// Use this as the outermost wrapper for any test that controls the env.
private func withCleanEnv(_ body: () -> Void) {
    let prevGH     = ProcessInfo.processInfo.environment["GH_TOKEN"]
    let prevGitHub = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
    unsetenv("GH_TOKEN")
    unsetenv("GITHUB_TOKEN")
    body()
    if let prevGH     { setenv("GH_TOKEN",     prevGH,     1) } else { unsetenv("GH_TOKEN") }
    if let prevGitHub { setenv("GITHUB_TOKEN", prevGitHub, 1) } else { unsetenv("GITHUB_TOKEN") }
}

/// Sets a single env var for the duration of body, then restores previous value.
private func withEnv(_ key: String, value: String, _ body: () -> Void) {
    let previous = ProcessInfo.processInfo.environment[key]
    setenv(key, value, 1)
    body()
    if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
}

// MARK: - GitHubTokenCacheTests

/// Serialized so the process-global tokenCache is never shared across
/// concurrently running test bodies.
@Suite("GitHubTokenCache", .serialized)
struct GitHubTokenCacheTests {

    // MARK: - githubToken() — nil path

    /// Returns nil when neither env var is set and the Keychain is empty.
    @Test func githubToken_noSource_returnsNil() {
        defer { invalidateTokenCache() }
        withCleanEnv {
            #expect(githubToken() == nil)
        }
    }

    // MARK: - githubToken() — GH_TOKEN

    /// Resolves a token from GH_TOKEN when Keychain is empty.
    @Test func githubToken_ghTokenEnvVar_returnsToken() {
        defer { invalidateTokenCache() }
        withCleanEnv {
            withEnv("GH_TOKEN", value: "gh-test-token") {
                #expect(githubToken() == "gh-test-token")
            }
        }
    }

    // MARK: - githubToken() — GITHUB_TOKEN fallback

    /// Falls back to GITHUB_TOKEN when GH_TOKEN is absent.
    @Test func githubToken_githubTokenEnvVarFallback_returnsToken() {
        defer { invalidateTokenCache() }
        withCleanEnv {
            withEnv("GITHUB_TOKEN", value: "github-test-token") {
                #expect(githubToken() == "github-test-token")
            }
        }
    }

    /// Prefers GH_TOKEN over GITHUB_TOKEN when both are set.
    @Test func githubToken_bothEnvVarsSet_prefersGhToken() {
        defer { invalidateTokenCache() }
        withCleanEnv {
            withEnv("GH_TOKEN", value: "primary-token") {
                withEnv("GITHUB_TOKEN", value: "fallback-token") {
                    #expect(githubToken() == "primary-token")
                }
            }
        }
    }

    // MARK: - githubToken() — cache

    /// Returns the cached value on a second call without re-reading the environment.
    @Test func githubToken_secondCall_returnsFromCache() {
        defer { invalidateTokenCache() }
        withCleanEnv {
            withEnv("GH_TOKEN", value: "cached-token") {
                let first = githubToken() // populates cache
            }
            // Both env vars now absent; only the cache can satisfy the second call.
            let second = githubToken()
            #expect(second == "cached-token")
        }
    }

    // MARK: - invalidateTokenCache()

    /// Clears a populated cache so the next call re-resolves from source.
    @Test func invalidateTokenCache_clearsCache() {
        defer { invalidateTokenCache() }
        withCleanEnv {
            withEnv("GH_TOKEN", value: "original-token") {
                _ = githubToken() // populate cache
            }
            invalidateTokenCache()
            // Both env vars absent + cache cleared — must return nil.
            #expect(githubToken() == nil)
        }
    }

    /// Safe to call when the cache is already nil — does not crash.
    @Test func invalidateTokenCache_whenAlreadyNil_isNoop() {
        defer { invalidateTokenCache() }
        withCleanEnv {
            invalidateTokenCache() // must not crash on empty cache
            #expect(githubToken() == nil)
        }
    }
}
