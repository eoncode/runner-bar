import AppKit
import Foundation

// MARK: - OAuthService
//
// Implements the GitHub OAuth Authorization Code flow.
//
// Flow:
//   1. signIn() opens the GitHub authorization URL in the default browser.
//   2. The user clicks "Authorize" on GitHub's consent screen.
//   3. GitHub redirects to runnerbar://oauth/callback?code=...&state=...
//   4. AppDelegate.application(_:open:) catches the URL and calls handleCallback(_:).
//   5. handleCallback exchanges the code for an access token via POST to GitHub.
//   6. Token is saved to Keychain. onCompletion is called on the main thread.
//
// Client credentials are in Secrets.swift — see that file for why they are
// intentionally committed (open-source native app industry standard).

final class OAuthService {
    static let shared = OAuthService()
    private init() {}

    private let redirectURI = "runnerbar://oauth/callback"
    private let scopes = "repo read:org"

    /// Called on main thread after sign-in completes. `true` = success.
    var onCompletion: ((Bool) -> Void)?

    var isSignedIn: Bool { Keychain.token != nil }

    // MARK: Sign In

    func signIn() {
        var comps = URLComponents(string: "https://github.com/login/oauth/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: Secrets.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes)
        ]
        guard let url = comps.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Sign Out

    func signOut() {
        Keychain.delete()
        DispatchQueue.main.async { self.onCompletion?(false) }
    }

    // MARK: Callback Handler

    func handleCallback(_ url: URL) {
        guard
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            DispatchQueue.main.async { self.onCompletion?(false) }
            return
        }
        Task { await exchangeCode(code) }
    }

    // MARK: Token Exchange

    private func exchangeCode(_ code: String) async {
        guard let url = URL(string: "https://github.com/login/oauth/access_token") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_id": Secrets.clientID,
            "client_secret": Secrets.clientSecret,
            "code": code
        ])

        guard
            let (data, _) = try? await URLSession.shared.data(for: req),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = json["access_token"] as? String,
            !token.isEmpty
        else {
            DispatchQueue.main.async { self.onCompletion?(false) }
            return
        }

        Keychain.save(token)
        DispatchQueue.main.async { self.onCompletion?(true) }
    }
}
