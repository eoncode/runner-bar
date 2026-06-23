// OAuthService.swift
// RunnerBar
import AppKit
import Foundation

// MARK: - OAuthService
//
// Implements the GitHub OAuth Authorization Code flow.
//
// @MainActor ensures all access to `pendingState`, `onCompletion`, and
// `didSignOut` is serialised on the main thread. This matches how AppKit
// delivers application(_:open:) callbacks and how SwiftUI reads `isSignedIn`.
// It also silences the -strict-concurrency warning about non-Sendable
// captures of `self` in DispatchQueue.main.async closures.
//
// Flow:
// 1. signIn() generates a random state nonce, stores it, opens the GitHub
//    authorization URL (with state= param) in the default browser.
// 2. The user clicks "Authorize" on GitHub's consent screen.
// 3. GitHub redirects to runnerbar://oauth/callback?code=...&state=...
// 4. AppDelegate.application(_:open:) catches the URL and calls handleCallback(_:).
// 5. handleCallback verifies the state param matches pendingState (CSRF guard),
//    then exchanges the code for an access token via POST to GitHub.
// 6. Token is saved to Keychain (which also invalidates the token cache).
//    onCompletion is called on the main thread with the actual save result.
//
// Client credentials are in OAuthSecrets.swift — see that file for why they are
// intentionally committed (open-source native app industry standard).

/// Manages OAuthService state and behaviour.
@MainActor
final class OAuthService {
    /// The shared singleton instance.
    static let shared = OAuthService()
    /// Private initialiser — use `shared`.
    private init() {
        // Singleton — intentionally empty; all state is lazily initialised on first access.
    }

    /// Shared `JSONDecoder` — reused across token-exchange decode calls instead of per-call instantiation.
    private let decoder = JSONDecoder()
    /// Shared `JSONEncoder` — reused across token-exchange encode calls instead of per-call instantiation.
    private let encoder = JSONEncoder()

    /// The OAuth redirect URI. Must match the value registered in the GitHub OAuth app settings.
    /// Sourced from `GitHubConstants.oauthRedirectURI` — do not duplicate this string inline.
    private let redirectURI = GitHubConstants.oauthRedirectURI
    /// OAuth scopes requested during sign-in.
    ///
    /// - `repo`: Read access to repository runners, workflow runs, and job logs.
    ///   Required for all repo-scoped API calls (`/repos/{owner}/{repo}/actions/*`).
    /// - `read:org`: Read org membership and team info. Required to list org-level
    ///   runners via `/orgs/{org}/actions/runners` for users who are org members
    ///   but not owners.
    /// - `admin:org`: Broader org admin access. Required to call the runners API
    ///   on organisations where the authenticated user is an owner. Without this,
    ///   org-runner fetches return 403 for owner-level accounts.
    /// - `manage_runners:org`: Fine-grained scope (added in 2023) that explicitly
    ///   grants runner management on org level. Requested in addition to `admin:org`
    ///   for forward-compatibility as GitHub narrows older broad scopes.
    /// - `workflow`: Required to trigger and re-run workflow runs via the API.
    ///   Without this, dispatch and re-run actions fail with 403 even when `repo`
    ///   is present.
    ///
    /// Previously only `repo` and `read:org` were requested. The additional scopes
    /// were added because org-runner listing and workflow dispatch were returning 403
    /// for accounts with org-owner or org-admin roles.
    private let scopes = "repo read:org admin:org manage_runners:org workflow"

    // MARK: - OAuth endpoint constants
    /// GitHub OAuth authorisation URL — entry point for the browser-based sign-in flow.
    private let authorizeURL = "\(GitHubConstants.base)/login/oauth/authorize"
    /// GitHub OAuth token-exchange URL — receives the code and returns the access token.
    private let accessTokenURL = "\(GitHubConstants.base)/login/oauth/access_token"

    /// CSRF nonce generated in signIn(), verified in handleCallback().
    /// Cleared after use or on sign-out.
    private var pendingState: String?

    /// Called on main thread after sign-in completes. `true` = success.
    /// Register once in SettingsView.onAppearAction — do NOT re-assign in signIn().
    var onCompletion: ((Bool) -> Void)?

    // MARK: - Sign-out multicast
    //
    // Each caller receives its own dedicated AsyncStream via makeSignOutStream().
    // signOut() yields to every registered continuation, restoring the multicast
    // semantics of the old PassthroughSubject without reintroducing Combine.
    // AsyncStream is single-consumer — sharing one stream across multiple Tasks
    // would deliver each event to only one consumer (whichever wakes first).

    /// Registered continuations keyed by UUID — one per active consumer.
    /// Entries are removed automatically via `onTermination` when the consumer's
    /// Task is cancelled (e.g. SettingsView.onDisappear), preventing unbounded growth.
    private var signOutContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Returns a new `AsyncStream<Void>` that fires once per `signOut()` call.
    /// Each call site must request its own stream; the streams are multicasted.
    /// The continuation is removed from the registry when the consumer's Task
    /// is cancelled or the stream is otherwise terminated.
    /// Observe via:
    /// ```swift
    /// Task { for await _ in OAuthService.shared.makeSignOutStream() { … } }
    /// ```
    func makeSignOutStream() -> AsyncStream<Void> {
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

    // MARK: Sign In

    /// Opens the GitHub OAuth authorization page in the default browser to begin sign-in.
    func signIn() {
        log("OAuthService › signIn — initiating OAuth flow")
        let state = UUID().uuidString
        pendingState = state
        guard var comps = URLComponents(string: authorizeURL) else {
            log("OAuthService › signIn: malformed authorizeURL — aborting")
            pendingState = nil
            onCompletion?(false)
            return
        }
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: OAuthSecrets.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = comps.url else {
            log("OAuthService › signIn: failed to build authorization URL — aborting")
            pendingState = nil
            onCompletion?(false)
            return
        }
        // NOTE: pendingState is left set if the browser open fails silently.
        // handleCallback will CSRF-reject any eventual redirect with a mismatched
        // or absent state, so a stuck pendingState is safe — it will be cleared
        // on the next signIn(), signOut(), or a rejected handleCallback().
        log("OAuthService › signIn — opening browser for OAuth")
        NSWorkspace.shared.open(url)
    }

    // MARK: Sign Out

    /// Clears the stored token and emits `didSignOut` — but only when the token
    /// was actually removed from Keychain.
    ///
    /// Gating `didSignOut` on `deleted == true` prevents a "ghost sign-in" state
    /// where the UI shows signed-out while the old token remains in Keychain and
    /// subsequent API calls succeed as if the user were still authenticated.
    /// Mirrors the same pattern used in `exchangeCode()` where `onCompletion` is
    /// gated on the actual Keychain save result.
    func signOut() {
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

    // MARK: Callback Handler

    /// Handles the OAuth redirect URL from AppDelegate, verifying state and exchanging the code.
    func handleCallback(_ url: URL) {
        log("OAuthService › handleCallback — url=\(url.absoluteString)")
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            log("OAuthService › handleCallback — missing code param, calling onCompletion(false)")
            onCompletion?(false)
            return
        }
        // CSRF guard: verify the state param matches what we sent in signIn().
        guard let returnedState = comps.queryItems?.first(where: { $0.name == "state" })?.value else {
            log("OAuthService › handleCallback: no state param in redirect URL")
            pendingState = nil
            onCompletion?(false)
            return
        }
        guard returnedState == pendingState else {
            log("OAuthService › handleCallback: state mismatch — possible CSRF attempt, rejecting")
            pendingState = nil
            onCompletion?(false)
            return
        }
        log("OAuthService › handleCallback — state OK, exchanging code")
        pendingState = nil
        Task { await exchangeCode(code) }
    }

    // MARK: Token Exchange

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
        // OAuthTokenRequest contains only String fields and will always encode
        // successfully in practice. However, a nil httpBody would silently send
        // a broken POST to GitHub with no diagnostic — fail loudly instead.
        do {
            req.httpBody = try encoder.encode(body)
        } catch {
            log("OAuthService › exchangeCode: failed to encode request body — \(error)")
            onCompletion?(false)
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let response = try? decoder.decode(OAuthTokenResponse.self, from: data)
        else {
            log("OAuthService › exchangeCode — network/parse failure, calling onCompletion(false)")
            onCompletion?(false)
            return
        }
        // GitHub returns 200 even on failure; check for an error field before accessToken.
        if let errorCode = response.error {
            let desc = response.errorDescription ?? ""
            log("OAuthService › exchangeCode: GitHub error=\(errorCode) \(desc)")
            onCompletion?(false)
            return
        }
        guard let token = response.accessToken, !token.isEmpty else {
            log("OAuthService › exchangeCode: no access_token in response — keys=\(response.debugKeys)")
            onCompletion?(false)
            return
        }
        // Gate success on whether the token was actually persisted to Keychain.
        // If Keychain.save fails, report failure so the UI does not show signed-in
        // while Keychain.token remains nil and subsequent API calls lack auth.
        log("OAuthService › exchangeCode — got access_token (len=\(token.count)), saving to Keychain")
        let saved = Keychain.save(token)
        log("OAuthService › exchangeCode — Keychain.save result=\(saved), calling onCompletion(\(saved))")
        if !saved { log("OAuthService › exchangeCode: Keychain.save failed") }
        onCompletion?(saved)
    }
}

// MARK: - Private response models

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
        /// JSON key: `error` — maps directly (no rename).
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

/// Typed request body for the GitHub OAuth token-exchange POST.
///
/// Replaces the `[String: String]` dictionary literal previously used in
/// `exchangeCode(_:)`. Using a concrete `Encodable` struct:
/// - Makes the three required fields explicit and compiler-checked.
/// - Eliminates stringly-typed key spellings (`"client_id"` etc.) at the call site.
/// - Documents the contract of the GitHub OAuth token endpoint inline.
// periphery:ignore:all
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
        case clientID     = "client_id"
        /// JSON key: `client_secret`.
        case clientSecret = "client_secret"
        /// JSON key: `code` — maps directly (no rename).
        case code
    }
}
