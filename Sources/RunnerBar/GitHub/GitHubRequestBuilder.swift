// GitHubRequestBuilder.swift
// RunnerBar

import Foundation

// MARK: - URL helpers

/// Module-level constant reused by `resolveURL` to avoid allocating a new
/// `CharacterSet` on every API call and pagination iteration.
private let slashCharacterSet = CharacterSet(charactersIn: "/")

/// Resolves an endpoint string to a full GitHub API URL string.
func resolveURL(_ endpoint: String) -> String {
    endpoint.hasPrefix("http")
        ? endpoint
        : "\(GitHubConstants.apiBase)/\(endpoint.trimmingCharacters(in: slashCharacterSet))"
}

// MARK: - Request factories

/// Builds a URLRequest with the standard GitHub API headers shared by all
/// request types: `Authorization`, `X-GitHub-Api-Version`.
/// Callers set the `Accept` header for their specific media type.
func makeBaseRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return req
}

/// Builds a pre-configured URLRequest with standard GitHub API headers
/// and `application/vnd.github+json` Accept header.
func makeRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = makeBaseRequest(url: url, token: token, timeout: timeout)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    return req
}

/// Builds a URLRequest with `application/vnd.github.v3.raw` Accept header.
/// Used for log endpoints that 302-redirect to raw S3 content.
///
/// # S3 redirect safety
/// The `Authorization: Bearer` header set here is sent only to api.github.com.
/// When GitHub replies with 302 to a pre-signed S3 URL (*.amazonaws.com),
/// Apple's URLSession automatically strips sensitive headers — including
/// `Authorization` — before following the redirect to a different domain
/// (cross-origin redirect semantics per RFC 7235 / Apple URLSession behaviour).
/// S3 therefore receives only the pre-signed query-param credentials and no
/// conflicting `Authorization` header. No custom redirect delegate is required.
func makeRawRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = makeBaseRequest(url: url, token: token, timeout: timeout)
    req.setValue("application/vnd.github.v3.raw", forHTTPHeaderField: "Accept")
    return req
}
