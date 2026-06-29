// GitHubTokenCacheTests.swift
// RunBotCoreTests
//
// ⚠️ ISOLATION REQUIREMENT
// tokenCache is a process-global Mutex(nil) at module scope. Every test body
// calls invalidateTokenCache() at ENTRY (to flush state left by any concurrently
// finishing suite) and again in a defer at exit (to clean up for the next test
// in this serialized suite).
//
// The suite is marked .serialized so tests within it never race on tokenCache.
// The entry invalidation guards against other suites in the same test process
// that may have populated the cache before this suite starts.
//
// Keychain is never touched: token resolution is exercised through environment
// variables only (GH_TOKEN / GITHUB_TOKEN), keeping these tests sandboxing-free
// and safe to run with `swift test`.
//
// CI note: GitHub Actions always injects GITHUB_TOKEN into the runner environment.
// Every test wraps its body in withCleanEnv, which strips both vars and restores
// them afterwards.

import Foundation
import Testing

@testable import RunBotCore

// MARK: - Helpers

/// Strips both token env vars, runs body, then restores the previous values.
private func withCleanEnv(_ body: () -> Void) {
  let prevGH = ProcessInfo.processInfo.environment["GH_TOKEN"]
  let prevGitHub = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
  unsetenv("GH_TOKEN")
  unsetenv("GITHUB_TOKEN")
  body()
  if let prevGH { setenv("GH_TOKEN", prevGH, 1) } else { unsetenv("GH_TOKEN") }
  if let prevGitHub { setenv("GITHUB_TOKEN", prevGitHub, 1) } else { unsetenv("GITHUB_TOKEN") }
}

/// Sets one env var for the duration of body, then restores the previous value.
private func withEnv(_ key: String, value: String, _ body: () -> Void) {
  let previous = ProcessInfo.processInfo.environment[key]
  setenv(key, value, 1)
  body()
  if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
}

// MARK: - GitHubTokenCacheTests

@Suite("GitHubTokenCache", .serialized)
struct GitHubTokenCacheTests {

  // MARK: - githubToken() — nil path

  /// Returns nil when neither env var is set and the Keychain is empty.
  @Test func githubToken_noSource_returnsNil() {
    invalidateTokenCache()  // flush any cache from other suites
    defer { invalidateTokenCache() }
    withCleanEnv {
      #expect(githubToken() == nil)
    }
  }

  // MARK: - githubToken() — GH_TOKEN

  /// Resolves a token from GH_TOKEN when Keychain is empty.
  @Test func githubToken_ghTokenEnvVar_returnsToken() {
    invalidateTokenCache()
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
    invalidateTokenCache()
    defer { invalidateTokenCache() }
    withCleanEnv {
      withEnv("GITHUB_TOKEN", value: "github-test-token") {
        #expect(githubToken() == "github-test-token")
      }
    }
  }

  /// Prefers GH_TOKEN over GITHUB_TOKEN when both are set.
  @Test func githubToken_bothEnvVarsSet_prefersGhToken() {
    invalidateTokenCache()
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
    invalidateTokenCache()
    defer { invalidateTokenCache() }
    withCleanEnv {
      withEnv("GH_TOKEN", value: "cached-token") {
        _ = githubToken()  // populate cache; result discarded intentionally
      }
      // Both env vars now absent — only the in-memory cache can return a value.
      #expect(githubToken() == "cached-token")
    }
  }

  // MARK: - invalidateTokenCache()

  /// Clears a populated cache so the next call re-resolves from source.
  @Test func invalidateTokenCache_clearsCache() {
    invalidateTokenCache()
    defer { invalidateTokenCache() }
    withCleanEnv {
      withEnv("GH_TOKEN", value: "original-token") {
        _ = githubToken()  // populate cache
      }
      invalidateTokenCache()
      // Cache cleared + both env vars absent — must return nil.
      #expect(githubToken() == nil)
    }
  }

  /// Safe to call when the cache is already nil — does not crash.
  @Test func invalidateTokenCache_whenAlreadyNil_isNoop() {
    invalidateTokenCache()
    defer { invalidateTokenCache() }
    withCleanEnv {
      invalidateTokenCache()  // must not crash on empty cache
      #expect(githubToken() == nil)
    }
  }
}
