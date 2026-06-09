// GitHubResponseDecoder.swift
// RunnerBar

import Foundation

// MARK: - Error logging

/// Logs the response body (up to 400 chars) for non-2xx responses.
///
/// Intentionally internal: called from `GitHubURLSessionTransport` across the
/// file boundary introduced by the transport split. No side-effects beyond logging.
func logErrorBody(_ data: Data?, endpoint: String, status: Int) {
    guard let data, !data.isEmpty else { return }
    let body = String(data: data, encoding: .utf8) ?? "<non-UTF8, \(data.count)b>"
    let preview = body.count > 400 ? String(body.prefix(400)) + "…" : body
    log("URLSessionTransport › \(endpoint) status=\(status) body: \(preview)")
}

// MARK: - Rate-limit response handling

/// Handles a 403/429 HTTP response, setting rate-limit state when appropriate.
///
/// **Primary rate limits** (`429`, or `403` with `X-RateLimit-Remaining == 0`):
/// detected via status code or the remaining-quota header.
///
/// **Secondary rate limits** (`403` with a `Retry-After` header and non-zero remaining):
/// GitHub uses this for per-minute abuse / concurrency throttling. The `Retry-After`
/// value (seconds) is used as the reset delay so the timer honours the server window.
/// See https://docs.github.com/en/rest/overview/rate-limits-for-the-rest-api#secondary-rate-limits
func handleRateLimitResponse(
    statusCode: Int,
    _ data: Data?,
    response: HTTPURLResponse,
    endpoint: String
) async {
    let resetTS = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
        .flatMap { TimeInterval($0) }
    let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
        .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
    let isRealRateLimit = statusCode == 429 || remaining == 0 || retryAfter != nil
    if isRealRateLimit {
        logErrorBody(data, endpoint: endpoint, status: statusCode)
        let limitKind = retryAfter != nil && remaining != 0 ? "secondary" : "primary"
        log("URLSessionTransport › ⚠️ rate limited (\(limitKind)) — \(endpoint) status=\(statusCode)")
        let effectiveResetTS: TimeInterval?
        if let retryAfter, resetTS == nil {
            effectiveResetTS = Date().timeIntervalSince1970 + retryAfter
        } else {
            effectiveResetTS = resetTS
        }
        await rateLimitActor.set(resetAt: effectiveResetTS)
    } else {
        log("URLSessionTransport › 403 permission error (not rate limit) — \(endpoint)")
    }
}

// MARK: - Pagination

/// Parses the `Link` header from a GitHub paginated response and returns the `next` URL, if any.
///
/// Intentionally internal: called from `GitHubURLSessionTransport` across the file boundary.
func extractNextURL(from header: String?) -> String? {
    guard let header else { return nil }
    for part in header.components(separatedBy: ",") {
        let segments = part.components(separatedBy: ";")
        guard segments.count >= 2 else { continue }
        let linkSegment = segments[0].trimmingCharacters(in: .whitespaces)
        guard linkSegment.hasPrefix("<"), linkSegment.hasSuffix(">") else { continue }
        let link = String(linkSegment.dropFirst().dropLast())
        let isNext = segments.dropFirst().contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "rel=\"next\""
        })
        if isNext { return link }
    }
    return nil
}
