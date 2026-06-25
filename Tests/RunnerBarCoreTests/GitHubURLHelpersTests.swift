// GitHubURLHelpersTests.swift
// RunnerBarCoreTests
//
// Covers the canonical scope-derivation helpers introduced in F-52:
//   scopeFromUrl(_ url: URL) -> String?
//   scopeFromHtmlUrl(_ urlString: String?) -> String?
//
// Both functions are pure and synchronous — no async, no concurrency helpers needed.

import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - scopeFromUrl

@Suite("scopeFromUrl")
struct ScopeFromUrlTests {

    // MARK: Happy paths

    /// Repo-scoped URL returns "owner/repo".
    @Test func repoScoped_returnsOwnerSlashRepo() {
        let url = URL(string: "https://github.com/acme/my-repo")!
        #expect(scopeFromUrl(url) == "acme/my-repo")
    }

    /// Org-scoped URL (single path component) returns the org name.
    @Test func orgScoped_returnsOrgName() {
        let url = URL(string: "https://github.com/acme")!
        #expect(scopeFromUrl(url) == "acme")
    }

    /// Trailing slash on a repo URL is handled correctly.
    @Test func repoScoped_trailingSlash_returnsOwnerSlashRepo() {
        let url = URL(string: "https://github.com/acme/my-repo/")!
        #expect(scopeFromUrl(url) == "acme/my-repo")
    }

    // MARK: Nil path

    /// A bare host with no path components returns nil.
    @Test func bareHost_returnsNil() {
        let url = URL(string: "https://github.com")!
        #expect(scopeFromUrl(url) == nil)
    }

    /// A bare host with a trailing slash (single "/" component only) returns nil.
    @Test func bareHostTrailingSlash_returnsNil() {
        let url = URL(string: "https://github.com/")!
        #expect(scopeFromUrl(url) == nil)
    }

    // MARK: Double-slash path (malformed URLs)

    /// A double-slash path (e.g. https://github.com//acme) must not produce
    /// a scope with a leading slash. The empty component between the two slashes
    /// is filtered out by the `!$0.isEmpty` guard, leaving just "acme".
    @Test func doubleSlashPath_orgOnly_filtersEmptyComponent() {
        // URL(string:) preserves the double-slash in the path.
        let url = URL(string: "https://github.com//acme")!
        #expect(scopeFromUrl(url) == "acme")
    }

    /// A double-slash before the repo segment also filters correctly.
    @Test func doubleSlashPath_repoScoped_filtersEmptyComponent() {
        let url = URL(string: "https://github.com//acme/my-repo")!
        #expect(scopeFromUrl(url) == "acme/my-repo")
    }

    // MARK: 3+ path segments (intentional truncation)

    /// URLs with more than two path segments return only the first two.
    /// This is intentional: GitHub runner URLs are always owner/repo or org.
    /// Deeper paths (e.g. https://github.com/owner/repo/tree/main) are not
    /// valid runner registration URLs; truncation is documented behaviour.
    @Test func threeSegments_returnsFirstTwo() {
        let url = URL(string: "https://github.com/owner/repo/tree")!
        #expect(scopeFromUrl(url) == "owner/repo")
    }

    @Test func fourSegments_returnsFirstTwo() {
        let url = URL(string: "https://github.com/owner/repo/tree/main")!
        #expect(scopeFromUrl(url) == "owner/repo")
    }

    // MARK: Non-github.com host

    /// Works identically for non-github.com hosts (e.g. GitHub Enterprise).
    @Test func enterpriseHost_repoScoped_returnsOwnerSlashRepo() {
        let url = URL(string: "https://github.corp.example.com/owner/repo")!
        #expect(scopeFromUrl(url) == "owner/repo")
    }

    @Test func enterpriseHost_orgScoped_returnsOrgName() {
        let url = URL(string: "https://github.corp.example.com/myorg")!
        #expect(scopeFromUrl(url) == "myorg")
    }
}

// MARK: - scopeFromHtmlUrl

@Suite("scopeFromHtmlUrl")
struct ScopeFromHtmlUrlTests {

    // MARK: Happy paths — delegates to scopeFromUrl

    /// Repo-scoped URL string returns "owner/repo".
    @Test func repoScoped_returnsOwnerSlashRepo() {
        #expect(scopeFromHtmlUrl("https://github.com/acme/my-repo") == "acme/my-repo")
    }

    /// Org-scoped URL string returns the org name.
    @Test func orgScoped_returnsOrgName() {
        #expect(scopeFromHtmlUrl("https://github.com/acme") == "acme")
    }

    // MARK: Nil / invalid input

    /// nil input returns nil.
    @Test func nilInput_returnsNil() {
        #expect(scopeFromHtmlUrl(nil) == nil)
    }

    /// Empty string is not a valid URL; returns nil.
    @Test func emptyString_returnsNil() {
        #expect(scopeFromHtmlUrl("") == nil)
    }

    /// A non-URL string returns nil.
    @Test func invalidUrlString_returnsNil() {
        #expect(scopeFromHtmlUrl("not a url at all") == nil)
    }

    /// A bare host string with no path returns nil.
    @Test func bareHostString_returnsNil() {
        #expect(scopeFromHtmlUrl("https://github.com") == nil)
    }

    // MARK: Consistency with scopeFromUrl

    /// scopeFromHtmlUrl and scopeFromUrl return the same result for the same URL.
    @Test func consistencyWithScopeFromUrl_repoScoped() {
        let urlString = "https://github.com/acme/my-repo"
        let url = URL(string: urlString)!
        #expect(scopeFromHtmlUrl(urlString) == scopeFromUrl(url))
    }

    @Test func consistencyWithScopeFromUrl_orgScoped() {
        let urlString = "https://github.com/acme"
        let url = URL(string: urlString)!
        #expect(scopeFromHtmlUrl(urlString) == scopeFromUrl(url))
    }
}
