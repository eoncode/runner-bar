// GitHubURLSessionTransport.swift
// RunnerBar
import Foundation
import os

// MARK: - Rate limit flag

/// OSAllocatedUnfairLock state: (isRateLimited: Bool, resetItem: DispatchWorkItem?)
/// Both fields are mutated together under the same lock so the cancel-and-replace
/// of the reset timer is always atomic with the flag write.
private struct RateLimitState {
    /// The isLimited property.
    var isLimited: Bool = false
    /// The resetItem property.
    var resetItem: DispatchWorkItem?
}
/// The rateLimitLock constant.
private let rateLimitLock = OSAllocatedUnfairLock(initialState: RateLimitState())

/// The ghIsRateLimited property.
var ghIsRateLimited: Bool {
    get { rateLimitLock.withLock { $0.isLimited } }
    set {
        rateLimitLock.withLock { $0.isLimited = newValue }
        if newValue {
            // Auto-reset is scheduled by scheduleRateLimitReset(resetAt:).
            // If called without a header value (e.g. from a CLI code path),
            // fall back to a 60-minute window.
            scheduleRateLimitReset(resetAt: nil)
        }
    }
}

/// Schedules an automatic reset of `ghIsRateLimited` to `false`.
///
/// Uses a cancel-and-replace `DispatchWorkItem` so that multiple concurrent
/// 403/429 responses (e.g. from paginated requests) never leave more than one
/// pending reset timer in flight. The latest `X-RateLimit-Reset` value wins.
///
/// - Parameter resetAt: Unix timestamp from the `X-RateLimit-Reset` response
///   header. When non-nil the reset fires precisely at that time; otherwise
///   falls back to 60 minutes from now.
private func scheduleRateLimitReset(resetAt: TimeInterval?) {
    let delay: TimeInterval
    if let ts = resetAt {
        let secondsUntilReset = ts - Date().timeIntervalSince1970
        // Clamp: never fire in less than 5 s or more than 2 h.
        delay = min(max(secondsUntilReset, 5), 7200)
    } else {
        delay = 3600 // GitHub default: 60 min
    }
    log("ghIsRateLimited › auto-reset scheduled in \(Int(delay))s")

    // Cancel any previously scheduled reset before registering a new one.
    // This ensures concurrent 403/429 responses from paginated requests do
    // not stack up multiple timers that could prematurely clear the flag.
    let item = DispatchWorkItem {
        rateLimitLock.withLock {
            $0.isLimited = false
            $0.resetItem = nil
        }
        log("ghIsRateLimited › auto-reset after \(Int(delay))s")
    }
    rateLimitLock.withLock {
        $0.resetItem?.cancel()
        $0.resetItem = item
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
}

// MARK: - URLSession transport
//
// urlSessionAPI / urlSessionAPIPaginated use the Keychain token (set by OAuthService)
// with a plain URLSession + Authorization: Bearer header.
//
// Both functions present a synchronous interface to existing call sites (all of which
// dispatch via DispatchQueue.global()), but internally use async/await + URLSession.data(for:)
// so the underlying thread is freed during the network wait rather than blocked.
//
// Bridging pattern: a DispatchSemaphore is signalled from inside a Task once the
// await returns. The semaphore wait is extremely short — it only blocks until the
// async result is available, not for the duration of I/O.
// ⚠️ Must always be called from a background thread.
// All existing call sites dispatch via DispatchQueue.global().

// MARK: - Request builder

/// Builds a pre-configured URLRequest with standard GitHub API headers.
private func makeRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return req
}

/// Performs a single async URLSession fetch, handling rate-limit headers.
/// Returns `(data, linkHeader)` on success, or `nil` on error / non-2xx / rate-limit.
private func fetchPage(req: URLRequest) async -> (Data, String?)? {
    do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { return nil }
        log("urlSessionAPI › \(req.url?.absoluteString ?? "-") status=\(http.statusCode)")
        if http.statusCode == 403 || http.statusCode == 429 {
            let resetTS = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                .flatMap { TimeInterval($0) }
            rateLimitLock.withLock { $0.isLimited = true }
            scheduleRateLimitReset(resetAt: resetTS)
            return nil
        }
        guard (200..<300).contains(http.statusCode) else { return nil }
        let link = http.value(forHTTPHeaderField: "Link")
        return (data, link)
    } catch {
        log("urlSessionAPI › network error: \(error.localizedDescription)")
        return nil
    }
}

/// Fetches a single GitHub API page.
///
/// Internally uses `async/await` + `URLSession.data(for:)` so the GCD thread is
/// freed during the network wait. A `DispatchSemaphore` bridges the async result
/// back to the synchronous call site and signals immediately once the await returns.
/// ⚠️ Must be called from a background thread, never from the main thread.
func urlSessionAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let token = githubToken() else {
        log("urlSessionAPI › no token available")
        return nil
    }
    let urlString = endpoint.hasPrefix("http")
        ? endpoint
        : "\(GitHubConstants.apiBase)/\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    guard let url = URL(string: urlString) else {
        log("urlSessionAPI › invalid URL: \(urlString)")
        return nil
    }
    let req = makeRequest(url: url, token: token, timeout: timeout)
    let sem = DispatchSemaphore(value: 0)
    var result: Data?
    Task {
        result = await fetchPage(req: req).map { $0.0 }
        sem.signal()
    }
    sem.wait()
    return result
}

/// Fetches all pages of a GitHub API endpoint, concatenating JSON arrays.
/// Follows the `Link: <url>; rel="next"` header automatically.
///
/// Internally uses `async/await` + `URLSession.data(for:)` per page so GCD threads
/// are freed during each network wait. A `DispatchSemaphore` bridges the async
/// result back to the synchronous call site.
/// ⚠️ Must be called from a background thread, never from the main thread.
func urlSessionAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) -> Data? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let token = githubToken() else {
        log("urlSessionAPIPaginated › no token available")
        return nil
    }
    let firstURL: String = endpoint.hasPrefix("http")
        ? endpoint
        : "\(GitHubConstants.apiBase)/\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    let sem = DispatchSemaphore(value: 0)
    var allItems: [[String: Any]] = []
    Task {
        var nextURL: String? = firstURL
        while let urlString = nextURL {
            guard let url = URL(string: urlString) else { break }
            let req = makeRequest(url: url, token: token, timeout: timeout)
            guard let (data, linkHeader) = await fetchPage(req: req) else { break }
            if let page = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                allItems.append(contentsOf: page)
            }
            nextURL = extractNextURL(from: linkHeader)
        }
        sem.signal()
    }
    sem.wait()
    guard !allItems.isEmpty else { return nil }
    return try? JSONSerialization.data(withJSONObject: allItems)
}

/// Parses the `Link` header and returns the URL for `rel="next"`, if present.
private func extractNextURL(from header: String?) -> String? {
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

// MARK: - Public API entry points
//
// Prefer URLSession (native OAuth token) when available; fall back to gh CLI subprocess.
// The CLI fallback is skipped when ghIsRateLimited is true — a rate-limit hit on the
// URLSession path must not trigger a second outbound request via the CLI on the same cycle.

/// Performs the ghAPI operation.
func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    if githubToken() != nil {
        let data = urlSessionAPI(endpoint, timeout: timeout)
        // If the URLSession call set ghIsRateLimited, bail out immediately.
        // Falling through to the CLI would fire another request against a rate-limited API.
        if data != nil || ghIsRateLimited {
            if ghIsRateLimited { log("ghAPI › rate limited, skipping CLI fallback for: \(endpoint)") }
            return data
        }
    }
    return ghAPICLI(endpoint, timeout: timeout)
}

/// Performs the ghAPIPaginated operation.
func ghAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) -> Data? {
    if githubToken() != nil {
        let data = urlSessionAPIPaginated(endpoint, timeout: timeout)
        // If the URLSession call set ghIsRateLimited, bail out immediately.
        if data != nil || ghIsRateLimited {
            if ghIsRateLimited { log("ghAPIPaginated › rate limited, skipping CLI fallback for: \(endpoint)") }
            return data
        }
    }
    return ghAPIPaginatedCLI(endpoint, timeout: timeout)
}
