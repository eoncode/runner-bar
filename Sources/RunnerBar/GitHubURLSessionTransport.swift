import Foundation
import os

// MARK: - Rate limit flag

private let _rateLimitLock = OSAllocatedUnfairLock(initialState: false)

var ghIsRateLimited: Bool {
    get { _rateLimitLock.withLock { $0 } }
    set { _rateLimitLock.withLock { $0 = newValue } }
}

// MARK: - URLSession transport
//
// urlSessionAPI / urlSessionAPIPaginated use the Keychain token (set by OAuthService)
// with a plain URLSession + Authorization: Bearer header.
//
// Both functions block the calling thread via DispatchSemaphore.
// ⚠️ Must always be called from a background thread.
// All existing call sites dispatch via DispatchQueue.global().

private let apiBase = "https://api.github.com"

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
        : "\(apiBase)/\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    guard let url = URL(string: urlString) else {
        log("urlSessionAPI › invalid URL: \(urlString)")
        return nil
    }
    let req = makeRequest(url: url, token: token, timeout: timeout)

    let sem = DispatchSemaphore(value: 0)
    var result: Data?
    URLSession.shared.dataTask(with: req) { data, response, error in
        defer { sem.signal() }
        if let error {
            log("urlSessionAPI › network error: \(error.localizedDescription)")
            return
        }
        if let http = response as? HTTPURLResponse {
            log("urlSessionAPI › \(urlString) status=\(http.statusCode)")
            if http.statusCode == 403 || http.statusCode == 429 {
                ghIsRateLimited = true
                return
            }
            guard (200..<300).contains(http.statusCode) else { return }
        }
        result = data
    }.resume()
    sem.wait()
    return result
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
        : "\(apiBase)/\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    var allItems: [[String: Any]] = []

    while let urlString = nextURL {
        guard let url = URL(string: urlString) else { break }
        let req = makeRequest(url: url, token: token, timeout: timeout)

        let sem = DispatchSemaphore(value: 0)
        var pageData: Data?
        var linkHeader: String?
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let error {
                log("urlSessionAPIPaginated › network error: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 403 || http.statusCode == 429 {
                    ghIsRateLimited = true
                    return
                }
                guard (200..<300).contains(http.statusCode) else { return }
                linkHeader = http.value(forHTTPHeaderField: "Link")
            }
            pageData = data
        }.resume()
        sem.wait()

        guard let data = pageData else { break }
        if let page = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            allItems.append(contentsOf: page)
        }
        nextURL = extractNextURL(from: linkHeader)
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

func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    if githubToken() != nil {
        let data = urlSessionAPI(endpoint, timeout: timeout)
        if data != nil { return data }
    }
    return ghAPICLI(endpoint, timeout: timeout)
}

func ghAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) -> Data? {
    if githubToken() != nil {
        let data = urlSessionAPIPaginated(endpoint, timeout: timeout)
        if data != nil { return data }
    }
    return ghAPIPaginatedCLI(endpoint, timeout: timeout)
}
