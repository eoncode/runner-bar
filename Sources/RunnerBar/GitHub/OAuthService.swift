// OAuthService.swift
// RunnerBar
import AppKit
import Combine
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
// Client credentials are in Secrets.swift — see that file for why they are
// intentionally committed (open-source native app industry standard).

/// Manages OAuthService state and behaviour.
@MainActor
final class OAuthService {
    /// The shared singleton instance.
    static let shared = OAuthService()
    /// Private initialiser — use `shared`.
    private init() {
        // Singleton — intentionally empty; default property values are sufficient.
    }

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
    /// - `gist`: Required by some legacy GitHub operations. Absent from the token,
    ///   GitHub prompts for re-auth interactively.
    ///
    /// Previously only `repo` and `read:org` were requested. The additional scopes
    /// were added because org-runner listing and workflow dispatch were returning 403
    /// for accounts with org-owner or org-admin roles.
    private let scopes = "repo read:org admin:org manage_runners:org workflow gist"

    // MARK: - OAuth endpoint constants
    /// GitHub OAuth authorisation URL — entry point for the browser-based sign-in flow.
    private let authorizeURL    = "\(GitHubConstants.base)/login/oauth/authorize"
    /// GitHub OAuth token-exchange URL — receives the code and returns the access token.
    private let accessTokenURL  = "\(GitHubConstants.base)/login/oauth/access_token"

    /// CSRF nonce generated in signIn(), verified in handleCallback().
    /// Cleared after use or on sign-out.
    private var pendingState: String?

    /// Called on main thread after sign-in completes. `true` = success.
    /// Register once in SettingsView.onAppearAction — do NOT re-assign in signIn().
    var onCompletion: ((Bool) -> Void)?

    /// Emits on the main thread after a successful sign-out.
    /// Subscribe via `.sink { }.store(in: &cancellables)` — do NOT use a raw closure.
    let didSignOut = PassthroughSubject<Void, Never>()

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
            URLQueryItem(name: "client_id", value: Secrets.clientID),
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
            log("OAuthService › signOut — emitting didSignOut")
            didSignOut.send()
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
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_id": Secrets.clientID,
            "client_secret": Secrets.clientSecret,
            "code": code
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            log("OAuthService › exchangeCode — network/parse failure, calling onCompletion(false)")
            onCompletion?(false)
            return
        }
        // GitHub returns 200 even on failure; check for an error field before access_token.
        if let errorCode = json["error"] as? String {
            let desc = json["error_description"] as? String ?? ""
            log("OAuthService › exchangeCode: GitHub error=\(errorCode) \(desc)")
            onCompletion?(false)
            return
        }
        guard let token = json["access_token"] as? String, !token.isEmpty else {
            log("OAuthService › exchangeCode: no access_token in response — keys=\(json.keys.sorted())")
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
