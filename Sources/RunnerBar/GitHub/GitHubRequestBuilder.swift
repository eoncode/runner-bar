// GitHubRequestBuilder.swift
// RunnerBar

import Foundation

// MARK: - URL helpers

/// Resolves an endpoint string to a full GitHub API URL string.
/// Absolute URLs (starting with "http") are returned unchanged;
/// relative paths are prefixed with `GitHubConstants.apiBase`.
///
/// Intentionally internal: called from `GitHubURLSessionTransport` and
/// `GitHubResponseDecoder` across file boundaries introduced by the
/// transport split. `fileprivate` is not an option across files; internal
/// is the narrowest visibility that satisfies the requirement.
func resolveURL(_ endpoint: String) -> String {
    /// Module-level constant reused to avoid allocating a new `CharacterSet`
    /// on every API call and pagination iteration.
    let slashCharacterSet = CharacterSet(charactersIn: "/")
    return endpoint.hasPrefix("http")
        ? endpoint
        : "\(GitHubConstants.apiBase)/\(endpoint.trimmingCharacters(in: slashCharacterSet))"
}

// MARK: - Request factories

/// Builds a `URLRequest` with the headers common to all GitHub API requests:
/// `Authorization: Bearer`, `X-GitHub-Api-Version`.
/// Only called by `makeRequest` and `makeRawRequest` in this file.
private func makeBaseRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return req
}

/// Builds a pre-configured `URLRequest` with the standard `application/vnd.github+json` Accept header.
///
/// Intentionally internal: called from `GitHubURLSessionTransport` across the file
/// boundary introduced by the transport split. `makeBaseRequest` remains private.
func makeRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = makeBaseRequest(url: url, token: token, timeout: timeout)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    return req
}

/// Builds a `URLRequest` with the `application/vnd.github.v3.raw` Accept header.
/// Used for log endpoints that 302-redirect to raw S3 content.
///
/// Intentionally internal: called from `GitHubURLSessionTransport` across the file
/// boundary introduced by the transport split.
///
/// # S3 redirect safety
/// The `Authorization: Bearer` header is sent only to api.github.com.
/// Apple’s URLSession strips it before following a cross-origin redirect
/// (RFC 7235 / Apple URLSession behaviour), so the Bearer token is never
/// forwarded to S3. No custom redirect delegate is required.
func makeRawRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = makeBaseRequest(url: url, token: token, timeout: timeout)
    req.setValue("application/vnd.github.v3.raw", forHTTPHeaderField: "Accept")
    return req
}
