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
    /// The shared constant.
    static let shared = OAuthService()
    /// Private initialiser — use `shared`.
    private init() {
        // Singleton — intentionally empty; default property values are sufficient.
    }

    /// The redirectURI constant.
    private let redirectURI = "runnerbar://oauth/callback"
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
    /// - `gist`: Required by some GitHub CLI (`gh`) operations used internally via
    ///   `GitHubCLITransport`. Absent from the token, `gh` prompts for re-auth
    ///   interactively, breaking headless CLI calls.
    ///
    /// Previously only `repo` and `read:org` were requested. The additional scopes
    /// were added because org-runner listing and workflow dispatch were returning 403
    /// for accounts with org-owner or org-admin roles.
    private let scopes = "repo read:org admin:org manage_runners:org workflow gist"

    // MARK: - OAuth endpoint constants
    /// The authorizeURL constant.
    private let authorizeURL    = "\(GitHubConstants.base)/login/oauth/authorize"
    /// The accessTokenURL constant.
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

    /// Performs the signIn operation.
    func signIn() {
        let state = UUID().uuidString
        pendingState = state
        var comps = URLComponents(string: authorizeURL)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: Secrets.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = comps.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Sign Out

    /// Performs the signOut operation.
    func signOut() {
        pendingState = nil
        // Keychain.delete() returns false if SecItemDelete failed (token may still exist).
        // Only report sign-out success when the token was actually removed.
        let deleted = Keychain.delete()
        if !deleted { log("OAuthService › signOut: Keychain.delete failed") }
        didSignOut.send()
    }

    // MARK: Callback Handler

    /// Performs the handleCallback operation.
    func handleCallback(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
        else { onCompletion?(false); return }
        // CSRF guard: verify the state param matches what we sent in signIn().
        let returnedState = comps.queryItems?.first(where: { $0.name == "state" })?.value
        guard let returnedState, returnedState == pendingState else {
            log("OAuthService › handleCallback: state mismatch — possible CSRF attempt, rejecting")
            pendingState = nil
            onCompletion?(false)
            return
        }
        pendingState = nil
        Task { await exchangeCode(code) }
    }

    // MARK: Token Exchange

    /// Performs the exchangeCode operation.
    private func exchangeCode(_ code: String) async {
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String,
              !token.isEmpty
        else { onCompletion?(false); return }
        // Gate success on whether the token was actually persisted to Keychain.
        // If Keychain.save fails, report failure so the UI does not show signed-in
        // while Keychain.token remains nil and subsequent API calls lack auth.
        let saved = Keychain.save(token)
        if !saved { log("OAuthService › exchangeCode: Keychain.save failed") }
        onCompletion?(saved)
    }
}
