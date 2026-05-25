// GitHubURLSessionTransport.swift
// RunnerBar
@preconcurrency import Foundation
import os

// MARK: - Rate limit flag

/// Combined rate-limit state held under a single lock.
///
/// Both `isLimited` and `resetDate` are mutated together so that a reader
/// can never observe `isLimited == true` with a stale / nil `resetDate`.
///
/// Pipeline:
///   1. `urlSessionAPI` / `urlSessionAPIPaginated` receive a 403/429.
///   2. They write `isLimited = true` + `resetDate` under this lock and call
///      `scheduleRateLimitReset(resetAt:)` to auto-clear after the window.
///   3. `ghIsRateLimited` / `ghRateLimitResetDate` module vars expose the
///      current values for consumption on any thread.
///   4. `RunnerStore.applyFetchResult` copies both into its own
///      `@MainActor` properties (`isRateLimited`, `rateLimitResetDate`).
///   5. `RunnerViewModel.reload()` mirrors them into `@Published` props.
///   6. `PanelMainView.rateLimitBanner` renders a live countdown using
///      `store.rateLimitResetDate` + the existing 1-second `displayTick`.
///
/// `@unchecked Sendable` because `DispatchWorkItem?` is not itself `Sendable`;
/// all mutation is serialised through `rateLimitLock`.
private struct RateLimitState: @unchecked Sendable {
    /// Whether the GitHub API is currently rate-limiting this client.
    var isLimited: Bool = false
    /// The moment at which the rate-limit window expires (mirrors X-RateLimit-Reset).
    /// `nil` when the reset time is unknown (e.g. CLI code path).
    var resetDate: Date?
    /// Pending work item that clears `isLimited` when it fires.
    var resetItem: DispatchWorkItem?
}

/// Lock that serialises all reads and writes to `RateLimitState`.
private let rateLimitLock = OSAllocatedUnfairLock(initialState: RateLimitState())

/// Thread-safe read/write access to the rate-limited flag.
///
/// Setting to `true` without a reset date (legacy / CLI path) schedules a
/// 60-minute auto-reset via `scheduleRateLimitReset(resetAt: nil)`.
var ghIsRateLimited: Bool {
    get { rateLimitLock.withLock { $0.isLimited } }
    set {
        rateLimitLock.withLock {
            $0.isLimited = newValue
            if !newValue { $0.resetDate = nil }
        }
        if newValue {
            scheduleRateLimitReset(resetAt: nil)
        }
    }
}

/// The exact `Date` at which the current rate-limit window expires.
///
/// `nil` when no rate-limit is active or when the reset time is unknown.
/// Updated atomically alongside `ghIsRateLimited` whenever a 403/429
/// response is received so consumers always see a consistent pair.
var ghRateLimitResetDate: Date? {
    rateLimitLock.withLock { $0.resetDate }
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
    let resetDate: Date
    if let ts = resetAt {
        let secondsUntilReset = ts - Date().timeIntervalSince1970
        delay = min(max(secondsUntilReset, 5), 7200)
        resetDate = Date(timeIntervalSince1970: ts)
    } else {
        delay = 3600
        resetDate = Date().addingTimeInterval(delay)
    }
    log("ghIsRateLimited › auto-reset scheduled in \(Int(delay))s (resetDate=\(resetDate))")

    let item = DispatchWorkItem {
        rateLimitLock.withLock {
            $0.isLimited = false
            $0.resetDate = nil
            $0.resetItem = nil
        }
        log("ghIsRateLimited › auto-reset fired after \(Int(delay))s")
    }
    rateLimitLock.withLock {
        $0.resetItem?.cancel()
        $0.resetItem = item
        // Always update resetDate so ghRateLimitResetDate reflects the latest window.
        $0.resetDate = resetDate
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
}

// MARK: - URLSession transport
//
// urlSessionAPI / urlSessionAPIPaginated use the Keychain token (set by OAuthService)
// with a plain URLSession + Authorization: Bearer header.
//
// Both functions block the calling thread via DispatchSemaphore.
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

/// Fetches a single GitHub API page synchronously (blocking the calling thread).
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
    let result = OSAllocatedUnfairLock<Data?>(initialState: nil)
    URLSession.shared.dataTask(with: req) { data, response, error in
        defer { sem.signal() }
        if let error { log("urlSessionAPI › network error: \(error.localizedDescription)") ; return }
        if let http = response as? HTTPURLResponse {
            log("urlSessionAPI › \(urlString) status=\(http.statusCode)")
            if http.statusCode == 403 || http.statusCode == 429 {
                let resetTS = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                    .flatMap { TimeInterval($0) }
                rateLimitLock.withLock { $0.isLimited = true }
                scheduleRateLimitReset(resetAt: resetTS)
                return
            }
            guard (200..<300).contains(http.statusCode) else { return }
        }
        result.withLock { $0 = data }
    }.resume()
    sem.wait()
    return result.withLock { $0 }
}

/// Fetches all pages of a GitHub API endpoint, concatenating JSON arrays.
/// Follows the `Link: <url>; rel="next"` header automatically.
/// ⚠️ Must be called from a background thread, never from the main thread.
func urlSessionAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) -> Data? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let token = githubToken() else {
        log("urlSessionAPIPaginated › no token available")
        return nil
    }
    var nextURL: String? = endpoint.hasPrefix("http")
        ? endpoint
        : "\(GitHubConstants.apiBase)/\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    var allItems: [[String: Any]] = []
    while let urlString = nextURL {
        guard let url = URL(string: urlString) else { break }
        let req = makeRequest(url: url, token: token, timeout: timeout)
        let sem = DispatchSemaphore(value: 0)
        let pageData = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let linkHeader = OSAllocatedUnfairLock<String?>(initialState: nil)
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let error { log("urlSessionAPIPaginated › network error: \(error.localizedDescription)") ; return }
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 403 || http.statusCode == 429 {
                    let resetTS = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                        .flatMap { TimeInterval($0) }
                    rateLimitLock.withLock { $0.isLimited = true }
                    scheduleRateLimitReset(resetAt: resetTS)
                    return
                }
                guard (200..<300).contains(http.statusCode) else { return }
                linkHeader.withLock { $0 = http.value(forHTTPHeaderField: "Link") }
            }
            pageData.withLock { $0 = data }
        }.resume()
        sem.wait()
        guard let data = pageData.withLock({ $0 }) else { break }
        if let page = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            allItems.append(contentsOf: page)
        }
        nextURL = extractNextURL(from: linkHeader.withLock({ $0 }))
    }
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

/// Calls the GitHub API for a single page, preferring URLSession over the gh CLI.
/// Falls back to the CLI when no OAuth token is available or URLSession returns nil.
func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    if githubToken() != nil {
        let data = urlSessionAPI(endpoint, timeout: timeout)
        if data != nil || ghIsRateLimited {
            if ghIsRateLimited { log("ghAPI › rate limited, skipping CLI fallback for: \(endpoint)") }
            return data
        }
    }
    return ghAPICLI(endpoint, timeout: timeout)
}

/// Calls the GitHub API for all pages, preferring URLSession over the gh CLI.
/// Falls back to the CLI when no OAuth token is available or URLSession returns nil.
func ghAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) -> Data? {
    if githubToken() != nil {
        let data = urlSessionAPIPaginated(endpoint, timeout: timeout)
        if data != nil || ghIsRateLimited {
            if ghIsRateLimited { log("ghAPIPaginated › rate limited, skipping CLI fallback for: \(endpoint)") }
            return data
        }
    }
    return ghAPIPaginatedCLI(endpoint, timeout: timeout)
}
