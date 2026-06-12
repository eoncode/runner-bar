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
///
/// Only arms the actor when the response is a **genuine** rate-limit signal:
/// - HTTP 429 (always a rate-limit by definition)
/// - HTTP 403 with `X-RateLimit-Remaining: 0` (primary rate limit exhausted)
/// - HTTP 403 with a `Retry-After` header (secondary / abuse rate limit)
///
/// A plain 403 with none of those signals is a **permission error** (wrong token
/// scope, revoked PAT, repo access denial) and must **not** arm the actor —
/// doing so would lock the app out of the API for up to 60 minutes even though
/// no rate limit was hit.
///
/// See https://docs.github.com/en/rest/overview/rate-limits-for-the-rest-api
func handleRateLimitResponse(
    statusCode: Int,
    _ data: Data?,
    response: HTTPURLResponse,
    endpoint: String
) async {
    let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
        .flatMap(Double.init)
    let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        .flatMap(Int.init)
    let resetHeader = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
        .flatMap(TimeInterval.init)

    // Distinguish genuine rate-limit 403s from permission-denied 403s.
    // A 429 is always a rate limit; a 403 is only a rate limit when
    // Remaining == 0 or a Retry-After window is present.
    let isRealRateLimit = statusCode == 429 || remaining == 0 || retryAfter != nil
    guard isRealRateLimit else {
        log("RateLimit › 403 permission error (not rate limit) — \(endpoint)")
        return
    }

    // Log the response body to aid debugging — rate-limit responses from GitHub
    // often include a message field explaining the specific limit that was hit.
    logErrorBody(data, endpoint: endpoint, status: statusCode)

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
/// Uses `>= 2` to tolerate RFC 8288 multi-parameter parts (e.g. `rel="next"; hreflang="en"`).
func extractNextURL(from header: String?) -> String? {
    guard let header else { return nil }
    for part in header.components(separatedBy: ",") {
        let segments = part.components(separatedBy: ";")
        guard segments.count >= 2 else { continue }
        let rel = segments[1].trimmingCharacters(in: .whitespaces)
        guard rel == "rel=\"next\"" else { continue }
        let urlPart = segments[0].trimmingCharacters(in: .whitespaces)
        if urlPart.hasPrefix("<"), urlPart.hasSuffix(">") {
            return String(urlPart.dropFirst().dropLast())
        }
    }
    return nil
}
