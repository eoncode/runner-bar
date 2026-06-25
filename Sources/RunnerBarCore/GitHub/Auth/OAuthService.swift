// OAuthService.swift
// RunnerBarCore
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
// 3. GitHub redirects to runnerbar://oauth/callback?code=...&state=...
// 4. AppDelegate.application(_:open:) catches the URL and calls handleCallback(_:).
// 5. handleCallback verifies the state param matches pendingState (CSRF guard),
//    then exchanges the code for an access token via POST to GitHub.
// 6. Token is saved to Keychain. fireSignIn(_:) yields the result to all
//    registered makeSignInStream() consumers.

/// Manages OAuth state and behaviour. Lives in RunnerBarCore — no AppKit dependency.
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
        log("OAuthService › fireSignIn — success=\(success), consumers=\(signInContinuations.count)")
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
        log("OAuthService › makeSignInURL — building OAuth URL")
        let state = UUID().uuidString
        pendingState = state
        guard var comps = URLComponents(string: authorizeURL) else {
            log("OAuthService › makeSignInURL: malformed authorizeURL — aborting")
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
            log("OAuthService › makeSignInURL: failed to build URL — aborting")
            pendingState = nil
            return nil
        }
        log("OAuthService › makeSignInURL — URL built, returning to caller")
        return url
    }

    // MARK: - Sign Out

    /// Clears the stored token and emits a sign-out event to all stream consumers.
    public func signOut() {
        log("OAuthService › signOut — called, pendingState=\(pendingState != nil ? "set" : "nil")")
        pendingState = nil
        let deleted = Keychain.delete()
        log("OAuthService › signOut — Keychain.delete result=\(deleted)")
        if deleted {
            log("OAuthService › signOut — emitting didSignOut to \(signOutContinuations.count) consumer(s)")
            signOutContinuations.values.forEach { $0.yield(()) }
        } else {
            log("OAuthService › signOut: Keychain.delete failed — sign-out suppressed to prevent ghost sign-in")
        }
    }

    // MARK: - Callback Handler

    /// Handles the OAuth redirect URL from AppDelegate, verifying state and exchanging the code.
    public func handleCallback(_ url: URL) {
        log("OAuthService › handleCallback — url=\(url.absoluteString)")
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            log("OAuthService › handleCallback — missing code param, calling fireSignIn(false)")
            fireSignIn(false)
            return
        }
        guard let returnedState = comps.queryItems?.first(where: { $0.name == "state" })?.value else {
            log("OAuthService › handleCallback: no state param in redirect URL")
            pendingState = nil
            fireSignIn(false)
            return
        }
        guard returnedState == pendingState else {
            log("OAuthService › handleCallback: state mismatch — possible CSRF attempt, rejecting")
            pendingState = nil
            fireSignIn(false)
            return
        }
        log("OAuthService › handleCallback — state OK, exchanging code")
        pendingState = nil
        Task { await exchangeCode(code) }
    }

    // MARK: - Token Exchange

    /// POSTs the authorization code to GitHub and saves the returned access token to Keychain.
    private func exchangeCode(_ code: String) async {
        log("OAuthService › exchangeCode — POST to GitHub")
        guard let url = URL(string: accessTokenURL) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = OAuthTokenRequest(
            clientID: OAuthSecrets.clientID,
            clientSecret: OAuthSecrets.clientSecret,
            code: code
        )
        // OAuthTokenRequest contains only String fields — encode never throws in practice.
        // Treat a nil result as a hard failure rather than using do/catch.
        guard let httpBody = try? encoder.encode(body) else {
            log("OAuthService › exchangeCode: failed to encode request body — aborting")
            fireSignIn(false)
            return
        }
        req.httpBody = httpBody
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let response = try? decoder.decode(OAuthTokenResponse.self, from: data)
        else {
            log("OAuthService › exchangeCode — network/parse failure, calling fireSignIn(false)")
            fireSignIn(false)
            return
        }
        if let errorCode = response.error {
            let desc = response.errorDescription ?? ""
            log("OAuthService › exchangeCode: GitHub error=\(errorCode) \(desc)")
            fireSignIn(false)
            return
        }
        guard let token = response.accessToken, !token.isEmpty else {
            log("OAuthService › exchangeCode: no access_token in response — keys=\(response.debugKeys)")
            fireSignIn(false)
            return
        }
        log("OAuthService › exchangeCode — got access_token (len=\(token.count)), saving to Keychain")
        let saved = Keychain.save(token)
        log("OAuthService › exchangeCode — Keychain.save result=\(saved), calling fireSignIn(\(saved))")
        if !saved { log("OAuthService › exchangeCode: Keychain.save failed") }
        fireSignIn(saved)
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
