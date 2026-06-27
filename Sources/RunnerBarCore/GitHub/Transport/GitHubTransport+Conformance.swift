// GitHubTransport+Conformance.swift
// RunnerBarCore

import Foundation

// MARK: - GitHubTransport: protocol conformance

/// Conformance to ``GitHubTransportProtocol`` — all public API surface.
extension GitHubTransport {

    // MARK: apiAsync

    /// Fetches a single GitHub API page. Returns decoded `Data` on success, `nil` on any failure.
    @concurrent
    public func apiAsync(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
        guard case .success(let data, _, _) = await execute(
            endpoint, timeout: timeout, logTag: "apiAsync"
        ) else { return nil }
        return data
    }

    // MARK: apiPaginated

    /// Fetches and concatenates all pages for a GitHub paginated endpoint.
    /// Follows `Link: <url>; rel="next"` until all pages are consumed or an error stops pagination.
    ///
    /// - Returns `nil` on auth failure (401, permission-denied 403, missing/revoked token).
    /// - Returns `nil` when a stopping condition occurs before any items are accumulated.
    /// - Returns encoded `[]` (non-nil) when the endpoint returns a valid empty-array response.
    /// - Returns partial results when pagination stops mid-way due to rate-limit or network error.
    @concurrent
    public func apiPaginated(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
        var nextURL: String? = resolveURL(endpoint)
        var allItems: [AnyJSON] = []
        var didFailAuth = false
        var didRateLimit = false
        var hadAtLeastOneSuccessfulPage = false

        pagination: while let urlString = nextURL {
            let result = await execute(
                urlString, timeout: timeout, logTag: "apiPaginated"
            )
            switch result {
            case .success(let data, _, let linkHeader):
                if let page = try? decoder.decode([AnyJSON].self, from: data) {
                    hadAtLeastOneSuccessfulPage = true
                    allItems.append(contentsOf: page)
                    nextURL = extractNextURL(from: linkHeader)
                } else {
                    log("apiPaginated › unexpected non-array response at \(urlString) — stopping pagination", category: .transport)
                    break pagination
                }
            case .noToken:
                didFailAuth = true
                break pagination
            case .httpError(401):
                log("apiPaginated › 401 Unauthorized — token may have been revoked, stopping pagination", category: .transport)
                didFailAuth = true
                break pagination
            case .httpError:
                log("apiPaginated › non-2xx error at \(urlString) — stopping pagination", category: .transport)
                break pagination
            case .rateLimited:
                log("apiPaginated › rate limited — \(allItems.count) items collected so far", category: .transport)
                didRateLimit = true
                break pagination
            case .permissionDenied:
                log("apiPaginated › permission denied at \(urlString) — stopping pagination and discarding \(allItems.count) collected items", category: .transport)
                didFailAuth = true
                break pagination
            case .networkError:
                log("apiPaginated › network error at \(urlString) — stopping pagination", category: .transport)
                break pagination
            }
        }

        if didFailAuth {
            if allItems.isEmpty {
                log("apiPaginated › auth/permission failure on first page — returning nil", category: .transport)
            } else {
                log("apiPaginated › auth/permission failure mid-pagination — discarding \(allItems.count) collected items", category: .transport)
            }
            return nil
        }
        if didRateLimit {
            if allItems.isEmpty {
                log("apiPaginated › rate limited on first page — no items collected, returning nil", category: .transport)
                return nil
            }
            log("apiPaginated › pagination stopped by rate limit — returning \(allItems.count) partial items", category: .transport)
        }
        guard hadAtLeastOneSuccessfulPage else {
            log("apiPaginated › loop ended without any successful page — returning nil", category: .transport)
            return nil
        }
        do {
            let encoded = try encoder.encode(allItems)
            log("apiPaginated › returning \(allItems.count) items (\(encoded.count)b)", category: .transport)
            return encoded
        } catch {
            log("apiPaginated › encode failed: \(error) — returning nil", category: .transport)
            return nil
        }
    }

    // MARK: raw

    /// Fetches raw bytes from a GitHub API endpoint that 302-redirects to S3.
    @concurrent
    public func raw(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
        guard case .success(let data, _, _) = await execute(
            endpoint, timeout: timeout, logTag: "raw", useRawAccept: true
        ) else { return nil }
        log("raw › \(endpoint) → \(data.count)b", category: .transport)
        return data
    }

    // MARK: post

    /// Sends a POST to `endpoint`. Returns decoded response `Data`, or `nil` on failure.
    @concurrent
    @discardableResult
    public func post(_ endpoint: String, body: Data? = nil, timeout: TimeInterval = 30) async -> Data? {
        let result = await execute(endpoint, timeout: timeout, logTag: "post") { req in
            var request = req
            request.httpMethod = "POST"
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            return request
        }
        guard case .success(let data, let statusCode, _) = result else { return nil }
        log("post › \(endpoint) → \(statusCode)", category: .transport)
        return data
    }

    // MARK: put

    /// Sends a PUT with `body` to `endpoint`. Returns decoded response `Data`, or `nil` on failure.
    @concurrent
    public func put(_ endpoint: String, body: Data, timeout: TimeInterval = 30) async -> Data? {
        let result = await execute(endpoint, timeout: timeout, logTag: "put") { req in
            var request = req
            request.httpMethod = "PUT"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return request
        }
        guard case .success(let data, let statusCode, _) = result else { return nil }
        log("put › \(endpoint) → \(statusCode)", category: .transport)
        return data
    }

    // MARK: delete

    /// Sends a DELETE to `endpoint`. Returns `true` on 2xx, `false` otherwise.
    @concurrent
    @discardableResult
    public func delete(_ endpoint: String, timeout: TimeInterval = 30) async -> Bool {
        let result = await execute(endpoint, timeout: timeout, logTag: "delete") { req in
            var request = req
            request.httpMethod = "DELETE"
            return request
        }
        if case .success = result {
            log("delete › \(endpoint) → success", category: .transport)
            return true
        }
        return false
    }

    // MARK: cancelRun

    /// Cancels the workflow run identified by `runID` inside `scope`.
    ///
    /// - Note: Intentionally repo-only — GitHub does not provide a uniform
    ///   org-scoped cancel endpoint, so we only support `repo` scope here.
    @concurrent
    @discardableResult
    public func cancelRun(runID: Int, scope scopeString: String) async -> Bool {
        guard let scope = Scope.parse(scopeString) else {
            log("cancelRun › invalid scope: \(scopeString)", category: .transport)
            return false
        }
        // Intentionally repo-only: GitHub has no uniform org-scope cancel endpoint.
        // POST /repos/{owner}/{repo}/actions/runs/{run_id}/cancel exists; the org-level
        // equivalent does not. Org/enterprise callers must resolve to a repo scope first.
        guard case .repo = scope else {
            log("cancelRun › scope must be a repo (owner/name), got: \(scopeString)", category: .transport)
            return false
        }
        let endpoint = "\(scope.apiPrefix)/actions/runs/\(runID)/cancel"
        let executeResult = await execute(endpoint, timeout: 30, logTag: "cancelRun") { req in
            var request = req
            request.httpMethod = "POST"
            return request
        }
        switch executeResult {
        case .success:
            log("cancelRun › run=\(runID) scope=\(scopeString) success=true", category: .transport)
            return true
        case .httpError(let code):
            log("cancelRun › run=\(runID) scope=\(scopeString) failed — HTTP \(code)", category: .transport)
            return false
        case .noToken:
            log("cancelRun › run=\(runID) scope=\(scopeString) failed — no token", category: .transport)
            return false
        case .rateLimited:
            log("cancelRun › run=\(runID) scope=\(scopeString) failed — rate limited", category: .transport)
            return false
        case .permissionDenied:
            log("cancelRun › run=\(runID) scope=\(scopeString) failed — permission denied", category: .transport)
            return false
        case .networkError(let error):
            log("cancelRun › run=\(runID) scope=\(scopeString) failed — network error: \(error.localizedDescription)", category: .transport)
            return false
        }
    }

    // MARK: patchRunnerLabels

    /// Decoding model for the GitHub "set runner labels" PUT response.
    /// `private` to this file — used only by `patchRunnerLabels`.
    private struct LabelsResponse: Decodable {
        /// A single runner label entry returned by the GitHub API.
        struct Label: Decodable {
            /// The display name of the runner label.
            let name: String
        }
        /// The full list of labels attached to the runner after the PUT.
        let labels: [Label]
    }

    /// Replaces the labels on `runnerID` within `scope`. Returns the updated label list, or `nil`.
    @concurrent
    @discardableResult
    public func patchRunnerLabels(scope scopeString: String, runnerID: Int, labels: [String]) async -> [String]? {
        guard let scope = Scope.parse(scopeString) else {
            log("patchRunnerLabels › invalid scope: \(scopeString)", category: .transport)
            return nil
        }
        let endpoint = "\(scope.apiPrefix)/actions/runners/\(runnerID)/labels"
        log("patchRunnerLabels › PUT \(endpoint) labels=\(labels)", category: .transport)
        guard let bodyData = try? encoder.encode(["labels": labels]) else {
            log("patchRunnerLabels › failed to serialise request body", category: .transport)
            return nil
        }
        guard let outData = await put(endpoint, body: bodyData) else {
            log("patchRunnerLabels › request failed for endpoint=\(endpoint)", category: .transport)
            return nil
        }
        guard let resp = try? decoder.decode(LabelsResponse.self, from: outData) else {
            let raw = String(data: outData, encoding: .utf8) ?? ""
            log("patchRunnerLabels › decode failed raw=\(raw.prefix(200))", category: .transport)
            return nil
        }
        let names = resp.labels.map(\.name)
        log("patchRunnerLabels › success labels=\(names)", category: .transport)
        return names
    }

    // MARK: fetchRegistrationToken / fetchRemovalToken

    /// Fetches a short-lived registration token for the runner identified by `scope`.
    @concurrent
    public func fetchRegistrationToken(scope scopeString: String) async -> String? {
        guard let scope = Scope.parse(scopeString) else {
            log("fetchRegistrationToken › invalid scope: \(scopeString)", category: .transport)
            return nil
        }
        guard let token = await fetchRunnerToken(
            type: "registration-token", scope: scope, logPrefix: "fetchRegistrationToken"
        ) else { return nil }
        log("fetchRegistrationToken › got registration token", category: .transport)
        return token
    }

    /// Fetches a runner removal token for the given scope.
    @concurrent
    public func fetchRemovalToken(scope scopeString: String) async -> String? {
        guard let scope = Scope.parse(scopeString) else {
            log("fetchRemovalToken › invalid scope: \(scopeString)", category: .transport)
            return nil
        }
        guard let token = await fetchRunnerToken(
            type: "remove-token", scope: scope, logPrefix: "fetchRemovalToken"
        ) else { return nil }
        log("fetchRemovalToken › got removal token", category: .transport)
        return token
    }

    // MARK: deleteRunnerByID

    /// Removes the runner identified by `runnerID` from `scope`. Returns `true` on success.
    @concurrent
    @discardableResult
    public func deleteRunnerByID(scope scopeString: String, runnerID: Int) async -> Bool {
        guard let scope = Scope.parse(scopeString) else {
            log("deleteRunnerByID › invalid scope: \(scopeString)", category: .transport)
            return false
        }
        let endpoint = "\(scope.apiPrefix)/actions/runners/\(runnerID)"
        log("deleteRunnerByID › DELETE \(endpoint) runnerID=\(runnerID)", category: .transport)
        let success = await delete(endpoint)
        if !success { log("deleteRunnerByID › failed for runnerID=\(runnerID)", category: .transport) }
        return success
    }

    // MARK: - Private helpers

    /// Requests a runner token of the given `type` (registration or removal) for `scope`.
    @concurrent
    private func fetchRunnerToken(type: String, scope: Scope, logPrefix: String) async -> String? {
        let endpoint = "\(scope.apiPrefix)/actions/runners/\(type)"
        log("\(logPrefix) › POSTing \(endpoint)", category: .transport)
        guard let outputData = await post(endpoint) else {
            log("\(logPrefix) › request failed for \(endpoint)", category: .transport)
            return nil
        }
        guard !outputData.isEmpty else {
            log("\(logPrefix) › unexpected empty body for \(endpoint) (204?)", category: .transport)
            return nil
        }
        /// Short-lived installation token returned by the GitHub runner token endpoint.
        /// `private` to `fetchRunnerToken` — not part of any public API surface.
        struct TokenResponse: Decodable { let token: String }
        guard let resp = try? decoder.decode(TokenResponse.self, from: outputData) else {
            log("\(logPrefix) › decode failed (\(outputData.count)b)", category: .transport)
            return nil
        }
        return resp.token
    }
}
