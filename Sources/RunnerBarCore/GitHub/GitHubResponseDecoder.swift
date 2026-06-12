// GitHubResponseDecoder.swift
// RunnerBarCore

import Foundation

// MARK: - Error logging

/// Logs the response body (up to 400 chars) for non-2xx responses.
func logErrorBody(_ data: Data?, endpoint: String, status: Int) {
    guard let data, !data.isEmpty else { return }
    let body = String(data: data, encoding: .utf8) ?? "<non-UTF8, \(data.count)b>"
    let preview = body.count > 400 ? String(body.prefix(400)) + "…" : body
    log("HTTP \(status) \(endpoint): \(preview)")
}

// MARK: - Rate-limit response handler

/// Handles a 403 or 429 rate-limit response by forwarding to `RateLimitActor`.
/// GitHub uses this for per-minute abuse / concurrency throttling. The `Retry-After`
/// value (seconds) is used as the reset delay so the timer honours the server window.
/// See https://docs.github.com/en/rest/overview/rate-limits-for-the-rest-api#secondary-rate-limits
func handleRateLimitResponse(
    statusCode: Int,
    _ data: Data?,
    response: HTTPURLResponse,
    endpoint: String
) async {
    let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
        .flatMap(Double.init)
    let resetHeader = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
        .flatMap(TimeInterval.init)
    let resetAt: TimeInterval?
    if let retryAfter {
        resetAt = Date().timeIntervalSince1970 + retryAfter
    } else {
        resetAt = resetHeader
    }
    log(
        "RateLimit \(statusCode) \(endpoint) "
        + "retryAfter=\(String(describing: retryAfter)) "
        + "resetAt=\(String(describing: resetAt))"
    )
    await rateLimitActor.set(resetAt: resetAt)
}

// MARK: - Pagination

/// Parses the `Link` header from a GitHub paginated response and returns the `next` URL, if any.
func extractNextURL(from header: String?) -> String? {
    guard let header else { return nil }
    for part in header.components(separatedBy: ",") {
        let segments = part.components(separatedBy: ";")
        guard segments.count == 2 else { continue }
        let rel = segments[1].trimmingCharacters(in: .whitespaces)
        guard rel == "rel=\"next\"" else { continue }
        let urlPart = segments[0].trimmingCharacters(in: .whitespaces)
        if urlPart.hasPrefix("<"), urlPart.hasSuffix(">") {
            return String(urlPart.dropFirst().dropLast())
        }
    }
    return nil
}
