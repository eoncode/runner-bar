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

/// Handles a 403 or 429 rate-limit response by forwarding to the given `RateLimitActorProtocol`.
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
/// - Returns: `true` when this response was a genuine rate limit **and** the actor
///   was armed; `false` when the 403 is a plain permission error and the actor was
///   left unchanged. Callers **must** use this return value to classify the result
///   as `.rateLimited` vs `.permissionDenied` — reading the actor after the call
///   is a TOCTOU: a prior concurrent request may have already armed the actor,
///   causing a permission-denied 403 to be misclassified as a rate-limit.
///
/// - Parameter rateLimiter: The actor to arm on a genuine rate-limit.
///   **No default is provided intentionally.** This function is internal and
///   must always be called from `urlSessionExecute`, which threads its own
///   injected actor through. Providing a default here would silently fall back
///   to the global `rateLimitActor` if a caller ever bypassed `urlSessionExecute`,
///   defeating the injection contract and making test spies unreliable.
///
/// - Important: Do not call this function directly from outside `urlSessionExecute`.
///   The injection chain is: call site → `urlSessionAPIPaginated`/`urlSessionAPIAsync`
///   (default actor) → `urlSessionExecute` (passes actor through) → here.
///
/// - Parameter statusCode: The HTTP status code of the response.
/// - Parameter data: The response body, if any.
/// - Parameter response: The full `HTTPURLResponse`.
/// - Parameter endpoint: The endpoint string, used for logging.
/// - Parameter rateLimiter: The rate-limit actor to arm on a genuine rate-limit response.
///
/// See https://docs.github.com/en/rest/overview/rate-limits-for-the-rest-api
func handleRateLimitResponse(
    statusCode: Int,
    _ data: Data?,
    response: HTTPURLResponse,
    endpoint: String,
    rateLimiter: some RateLimitActorProtocol
) async -> Bool {
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
        return false
    }

    // Primary = quota exhausted (X-RateLimit-Remaining: 0).
    // Secondary = abuse / concurrency throttle (Retry-After present, or 429).
    // The distinction is operationally useful: primary means wait for reset window;
    // secondary means back off from request rate.
    let limitKind: String
    if retryAfter != nil || statusCode == 429 {
        limitKind = "secondary"
    } else {
        limitKind = "primary"
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
        "RateLimit › ⚠️ rate limited (\(limitKind)) — \(endpoint) "
            + "status=\(statusCode) "
            + "retryAfter=\(String(describing: retryAfter)) "
            + "resetAt=\(String(describing: resetAt))"
    )
    await rateLimiter.set(resetAt: resetAt)
    return true
}

// MARK: - Pagination

/// Parses the `Link` header from a GitHub paginated response and returns the `next` URL, if any.
///
/// Scans all semicolon-delimited tokens after the URL so `rel="next"` is found regardless
/// of its position in a multi-parameter Link part (RFC 8288 compliant).
func extractNextURL(from header: String?) -> String? {
    guard let header else { return nil }
    for part in header.components(separatedBy: ",") {
        let segments = part.components(separatedBy: ";")
        guard segments.count >= 2 else { continue }
        let hasNextRel = segments.dropFirst().contains {
            $0.trimmingCharacters(in: .whitespaces) == "rel=\"next\""
        }
        guard hasNextRel else { continue }
        let urlPart = segments[0].trimmingCharacters(in: .whitespaces)
        if urlPart.hasPrefix("<"), urlPart.hasSuffix(">") {
            return String(urlPart.dropFirst().dropLast())
        }
    }
    return nil
}
