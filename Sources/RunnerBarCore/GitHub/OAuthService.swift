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
// 6. Token is saved to Keychain (which also invalidates the token cache).
//    fireSignIn(_:) yields the result to all registered makeSignInStream() consumers.
//
// Client credentials are in OAuthSecrets.swift — see that file for why they are
// intentionally committed (open-source native app industry standard).

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

    // MARK: - OAuth endpoint constants
    private let authorizeURL = "\(GitHubConstants.base)/login/oauth/authorize"
    private let accessTokenURL = "\(GitHubConstants.base)/login/oauth/access_token"

    /// CSRF nonce generated in makeSignInURL(), verified in handleCallback().
    private var pendingState: String?

    // MARK: - Sign-out multicast

    private var signOutContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

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

    private var signInContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

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
    /// Returns `nil` if the URL cannot be constructed (failure is also fired to sign-in streams).
    public func makeSignInURL() -> URL? {
        log("OAuthService › makeSignInURL — building OAuth URL")
        let state = UUID().uuidString
        pendingState = state
        guard var comps = URLComponents(string: authorizeURL) else {
            log("OAuthService › makeSignInURL: malformed authorizeURL — aborting")
            pendingState = nil
            fireSignIn(false)
            return nil
        }
        comps.queryItems = [
            URLQueryItem(name: "client_id",    value: OAuthSecrets.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope",        value: scopes),
            URLQueryItem(name: "state",        value: state)
        ]
        guard let url = comps.url else {
            log("OAuthService › makeSignInURL: failed to build URL — aborting")
            pendingState = nil
            fireSignIn(false)
            return nil
        }
        log("OAuthService › makeSignInURL — URL built, returning to caller")
        return url
    }

    // MARK: - Sign Out

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
        do {
            req.httpBody = try encoder.encode(body)
        } catch {
            log("OAuthService › exchangeCode: failed to encode request body — \(error)")
            fireSignIn(false)
            return
        }
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

// MARK: - Private response models

private struct OAuthTokenResponse: Decodable {
    let accessToken: String?
    let error: String?
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken     = "access_token"
        case error
        case errorDescription = "error_description"
    }

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
private struct OAuthTokenRequest: Encodable {
    let clientID: String
    let clientSecret: String
    let code: String

    private enum CodingKeys: String, CodingKey {
        case clientID     = "client_id"
        case clientSecret = "client_secret"
        case code
    }
}
