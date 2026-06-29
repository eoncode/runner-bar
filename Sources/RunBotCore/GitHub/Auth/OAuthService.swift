// OAuthService.swift
// RunBotCore
import Foundation

// MARK: - OAuthService
//
// Implements the GitHub OAuth Authorization Code flow.
//
// @MainActor ensures all access to `pendingState` and continuation registries
// is serialised on the main thread. This matches how AppKit delivers
// application(_:open:) callbacks and how SwiftUI reads `isSignedIn`.
//
// Flow:
// 1. makeSignInURL() generates a random state nonce, stores it, and returns
//    the GitHub authorization URL. The caller is responsible for opening it
//    (e.g. NSWorkspace.shared.open(url) in SettingsView / AppDelegate).
// 2. The user clicks "Authorize" on GitHub's consent screen.
// 3. GitHub redirects to runbot://oauth/callback?code=...&state=...
// 4. AppDelegate.application(_:open:) catches the URL and calls handleCallback(_:).
// 5. handleCallback verifies the state param matches pendingState (CSRF guard),
//    then exchanges the code for an access token via POST to GitHub.
// 6. Token is saved to Keychain. fireSignIn(_:) yields the result to all
//    registered makeSignInStream() consumers.

/// Manages OAuth state and behaviour. Lives in RunBotCore — no AppKit dependency.
@MainActor
public final class OAuthService: OAuthServiceProtocol {
    /// Shared `JSONDecoder` — reused across token-exchange decode calls.
    private let decoder = JSONDecoder()
    /// Shared `JSONEncoder` — reused across token-exchange encode calls.
    private let encoder = JSONEncoder()
    /// The OAuth redirect URI. Must match the value registered in the GitHub OAuth app settings.
    private let redirectURI = GitHubConstants.oauthRedirectURI
    /// OAuth scopes requested during sign-in.
    private let scopes = "repo read:org admin:org manage_runners:org workflow"
    /// GitHub OAuth authorisation URL.
    private let authorizeURL = "\(GitHubConstants.base)/login/oauth/authorize"
    /// GitHub OAuth token-exchange URL.
    private let accessTokenURL = "\(GitHubConstants.base)/login/oauth/access_token"
    /// CSRF nonce generated in makeSignInURL(), verified in handleCallback(). Cleared after use.
    private var pendingState: String?

    /// Creates a new `OAuthService` instance.
    ///
    /// Declared explicitly as `public` because Swift does not promote a synthesised
    /// `init()` to `public` automatically, even when the enclosing type is `public`.
    public init() {}

    // MARK: - Sign-out multicast

    /// Registered sign-out continuations keyed by UUID — one per active consumer.
    private var signOutContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Returns a new `AsyncStream<Void>` that fires once per `signOut()` call.
    public func makeSignOutStream() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, cont) = AsyncStream<Void>.makeStream()
        signOutContinuations[id] = cont
        cont.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.signOutContinuations.removeValue(forKey: id)
            }
        }
        return stream
    }

    // MARK: - Sign-in multicast

    /// Registered sign-in continuations keyed by UUID — one per active consumer.
    private var signInContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    /// Returns a new `AsyncStream<Bool>` that fires once per sign-in attempt (`true` = success).
    public func makeSignInStream() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, cont) = AsyncStream<Bool>.makeStream()
        signInContinuations[id] = cont
        cont.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.signInContinuations.removeValue(forKey: id)
            }
        }
        return stream
    }

    /// Yields `success` to every registered sign-in continuation.
    private func fireSignIn(_ success: Bool) {
        log("OAuthService › fireSignIn — success=\(success), consumers=\(signInContinuations.count)", category: .transport)
        signInContinuations.values.forEach { $0.yield(success) }
    }

    // MARK: - Sign In

    /// Builds and returns the GitHub OAuth authorization URL, storing the CSRF nonce.
    ///
    /// The caller is responsible for opening the URL in the appropriate environment:
    /// ```swift
    /// if let url = oauthService.makeSignInURL() {
    ///     NSWorkspace.shared.open(url)  // app layer — not Core's concern
    /// }
    /// ```
    ///
    /// Returns `nil` if the URL cannot be constructed (both guard paths are unreachable
    /// at runtime — `authorizeURL` is a compile-time constant from `GitHubConstants`).
    ///
    /// **Stream asymmetry:** `makeSignInStream()` consumers are **not** notified when
    /// this method returns `nil`. No sign-in attempt reached the network, so no stream
    /// event is appropriate. The call site is responsible for handling `nil` directly
    /// (e.g. resetting `isSigningIn = false`). Only `handleCallback(_:)` and
    /// `exchangeCode(_:)` fire stream events, because those represent real sign-in
    /// outcomes.
    public func makeSignInURL() -> URL? {
        log("OAuthService › makeSignInURL — building OAuth URL", category: .transport)
        let state = UUID().uuidString
        pendingState = state
        guard var comps = URLComponents(string: authorizeURL) else {
            log("OAuthService › makeSignInURL: malformed authorizeURL — aborting", category: .transport)
            pendingState = nil
            return nil
        }
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: OAuthSecrets.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = comps.url else {
            log("OAuthService › makeSignInURL: failed to build URL — aborting", category: .transport)
            pendingState = nil
            return nil
        }
        log("OAuthService › makeSignInURL — URL built, returning to caller", category: .transport)
        return url
    }

    // MARK: - Sign Out

    /// Clears the stored token and emits a sign-out event to all stream consumers.
    public func signOut() {
        log("OAuthService › signOut — called, pendingState=\(pendingState != nil ? "set" : "nil")", category: .transport)
        pendingState = nil
        let deleted = Keychain.delete()
        log("OAuthService › signOut — Keychain.delete result=\(deleted)", category: .transport)
        if deleted {
            log("OAuthService › signOut — emitting didSignOut to \(signOutContinuations.count) consumer(s)", category: .transport)
            signOutContinuations.values.forEach { $0.yield(()) }
        } else {
            log("OAuthService › signOut: Keychain.delete failed — sign-out suppressed to prevent ghost sign-in", category: .transport)
        }
    }

    // MARK: - Callback Handler

    /// Handles the OAuth redirect URL from AppDelegate, verifying state and exchanging the code.
    public func handleCallback(_ url: URL) {
        // Log scheme+host only — the full URL contains the one-time `code` query parameter
        // which is sensitive for a short window. Logging url.absoluteString would expose
        // it to any process reading unified logs via `log stream`.
        let safeURL = "\(url.scheme ?? "")://\(url.host ?? "")"
        log("OAuthService › handleCallback — url=\(safeURL)", category: .transport)
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            log("OAuthService › handleCallback — missing code param, calling fireSignIn(false)", category: .transport)
            fireSignIn(false)
            return
        }
        guard let returnedState = comps.queryItems?.first(where: { $0.name == "state" })?.value else {
            log("OAuthService › handleCallback: no state param in redirect URL", category: .transport)
            pendingState = nil
            fireSignIn(false)
            return
        }
        guard returnedState == pendingState else {
            log("OAuthService › handleCallback: state mismatch — possible CSRF attempt, rejecting", category: .transport)
            pendingState = nil
            fireSignIn(false)
            return
        }
        log("OAuthService › handleCallback — state OK, exchanging code", category: .transport)
        pendingState = nil
        Task { await exchangeCode(code) }
    }

    // MARK: - Token Exchange

    /// POSTs the authorization code to GitHub and saves the returned access token to Keychain.
    ///
    /// Complexity is kept low by delegating each concern to a focused helper:
    /// - `makeTokenRequest(code:)` — builds the `URLRequest`
    /// - `fetchTokenData(request:)` — performs the network call
    /// - `handleTokenResponse(_:)` — validates the GitHub-level response
    private func exchangeCode(_ code: String) async {
        log("OAuthService › exchangeCode — POST to GitHub", category: .transport)
        let req: URLRequest
        do {
            req = try makeTokenRequest(code: code)
        } catch {
            log("OAuthService › exchangeCode: failed to encode request body — aborting", category: .transport)
            fireSignIn(false)
            return
        }
        let data: Data
        do {
            data = try await fetchTokenData(request: req)
        } catch {
            // Security note: `clientSecret` is sent as a JSON POST body field, not as part
            // of the request URL. `URLError.localizedDescription` never includes HTTP request
            // body content — only the URL and a human-readable error string — so logging
            // `error.localizedDescription` here cannot leak the client secret.
            // The endpoint URL (accessTokenURL) is not sensitive; it is a public GitHub API path.
            log("OAuthService › exchangeCode: network error — \(error.localizedDescription), calling fireSignIn(false)", category: .transport)
            fireSignIn(false)
            return
        }
        let response: OAuthTokenResponse
        do {
            response = try decoder.decode(OAuthTokenResponse.self, from: data)
        } catch {
            // Security note: the response body at this point is GitHub's token-exchange reply.
            // On success it contains only `access_token`; on failure it contains `error` and
            // `error_description` — no credentials that could be leaked. `DecodingError`
            // describes the structural mismatch (field name, type, path) and does not echo
            // raw JSON values in `localizedDescription`, so logging it here is safe.
            log("OAuthService › exchangeCode: decode error — \(error.localizedDescription), calling fireSignIn(false)", category: .transport)
            fireSignIn(false)
            return
        }
        guard let token = handleTokenResponse(response) else {
            fireSignIn(false)
            return
        }
        log("OAuthService › exchangeCode — got access_token (len=\(token.count)), saving to Keychain", category: .transport)
        let saved = Keychain.save(token)
        log("OAuthService › exchangeCode — Keychain.save result=\(saved), calling fireSignIn(\(saved))", category: .transport)
        if !saved { log("OAuthService › exchangeCode: Keychain.save failed", category: .transport) }
        fireSignIn(saved)
    }

    // MARK: - Token Exchange Helpers

    /// Builds the `URLRequest` for the GitHub token-exchange endpoint.
    ///
    /// - Parameter code: The one-time authorization code from the OAuth redirect.
    /// - Returns: A fully configured `URLRequest` ready to be sent.
    /// - Throws: `EncodingError` if the request body cannot be serialised.
    private func makeTokenRequest(code: String) throws -> URLRequest {
        guard let url = URL(string: accessTokenURL) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = OAuthTokenRequest(
            clientID: OAuthSecrets.clientID,
            clientSecret: OAuthSecrets.clientSecret,
            code: code
        )
        req.httpBody = try encoder.encode(body)
        return req
    }

    /// Performs the network call for the token exchange.
    ///
    /// - Parameter request: The pre-built `URLRequest` to send.
    /// - Returns: The raw response `Data`.
    /// - Throws: Any `URLError` from the underlying `URLSession`.
    private func fetchTokenData(request: URLRequest) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    /// Validates the GitHub-level token response and extracts the access token.
    ///
    /// Logs and returns `nil` for both GitHub-reported errors and missing/empty tokens.
    ///
    /// - Parameter response: The decoded `OAuthTokenResponse`.
    /// - Returns: The access token string on success; `nil` on failure.
    private func handleTokenResponse(_ response: OAuthTokenResponse) -> String? {
        if let errorCode = response.error {
            let desc = response.errorDescription ?? ""
            log("OAuthService › exchangeCode: GitHub error=\(errorCode) \(desc)", category: .transport)
            return nil
        }
        guard let token = response.accessToken, !token.isEmpty else {
            log("OAuthService › exchangeCode: no access_token in response — keys=\(response.debugKeys)", category: .transport)
            return nil
        }
        return token
    }
}

// MARK: - OAuthTokenResponse

/// Response body from the GitHub OAuth token exchange.
/// GitHub returns HTTP 200 even on failure, so both `accessToken` and `error` are optional.
private struct OAuthTokenResponse: Decodable {
    /// The access token returned on success; `nil` when GitHub reports an error.
    let accessToken: String?
    /// Short error code returned by GitHub on failure (e.g. `"bad_verification_code"`).
    let error: String?
    /// Human-readable description of the error, if present.
    let errorDescription: String?

    /// Maps Swift property names to the snake_case JSON keys returned by the GitHub OAuth endpoint.
    private enum CodingKeys: String, CodingKey {
        /// JSON key: `access_token`.
        case accessToken = "access_token"
        /// JSON key: `error`.
        case error
        /// JSON key: `error_description`.
        case errorDescription = "error_description"
    }

    /// Returns the names of modelled fields that are non-nil, for safe diagnostic logging.
    var debugKeys: [String] {
        var keys: [String] = []
        if accessToken != nil { keys.append("access_token") }
        if error != nil { keys.append("error") }
        if errorDescription != nil { keys.append("error_description") }
        return keys
    }
}

// MARK: - OAuthTokenRequest

// periphery:ignore
/// OAuth token-exchange request body for the GitHub API.
private struct OAuthTokenRequest: Encodable {
    /// The GitHub OAuth app client ID.
    let clientID: String
    /// The GitHub OAuth app client secret.
    let clientSecret: String
    /// The one-time authorization code received in the OAuth redirect callback.
    let code: String

    /// Maps Swift property names to the snake_case JSON keys expected by the GitHub OAuth endpoint.
    private enum CodingKeys: String, CodingKey {
        /// JSON key: `client_id`.
        case clientID = "client_id"
        /// JSON key: `client_secret`.
        case clientSecret = "client_secret"
        /// JSON key: `code`.
        case code
    }
}
