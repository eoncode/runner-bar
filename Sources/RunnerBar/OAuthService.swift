import AppKit
import Foundation

// MARK: - OAuthService

/// Owns the full GitHub OAuth Authorization Code flow.
///
/// Flow:
///  1. Open `https://github.com/login/oauth/authorize?…` in the default browser.
///  2. GitHub redirects to `runnerbar://oauth/callback?code=…`.
///  3. `AppDelegate` calls `OAuthService.shared.handleCallback(url:)`.
///  4. Service exchanges `code` for an access token via POST to
///     `https://github.com/login/oauth/access_token`.
///  5. Token is stored in the Keychain and the completion handler is called.
///
/// Client credentials are injected at build time via environment variables
/// `RUNNERBAR_CLIENT_ID` and `RUNNERBAR_CLIENT_SECRET` (see build.sh).
/// Hard-coded placeholders keep the build green without secrets in source.
final class OAuthService {
    /// The shared singleton instance used throughout the app.
    static let shared = OAuthService()
    private init() {}

    // MARK: - Client credentials

    /// GitHub OAuth App client ID.
    /// Override at build time: `RUNNERBAR_CLIENT_ID=xxx swift build`
    private var clientID: String {
        ProcessInfo.processInfo.environment["RUNNERBAR_CLIENT_ID"] ?? "PLACEHOLDER_CLIENT_ID"
    }

    /// GitHub OAuth App client secret.
    /// Override at build time: `RUNNERBAR_CLIENT_SECRET=xxx swift build`
    private var clientSecret: String {
        ProcessInfo.processInfo.environment["RUNNERBAR_CLIENT_SECRET"] ?? "PLACEHOLDER_CLIENT_SECRET"
    }

    // MARK: - State

    private var pendingState: String?
    /// Called on completion: `true` = signed in, `false` = cancelled/failed.
    var onCompletion: ((Bool) -> Void)?

    // MARK: - Sign in

    /// Starts the OAuth flow by opening the GitHub authorisation URL in the browser.
    /// - Parameter scopes: GitHub permission scopes (default: `repo` + `read:org`).
    func signIn(scopes: String = "repo,read:org") {
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        pendingState = state
        var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: "runnerbar://oauth/callback"),
            .init(name: "scope", value: scopes),
            .init(name: "state", value: state)
        ]
        guard let url = components.url else {
            log("OAuthService.signIn › failed to build URL")
            return
        }
        log("OAuthService.signIn › opening \(url)")
        NSWorkspace.shared.open(url)
    }

    // MARK: - Callback

    /// Called by `AppDelegate.application(_:open:)` when the `runnerbar://` URL is received.
    ///
    /// Validates the `state` parameter, then exchanges the `code` for an access token.
    func handleCallback(url: URL) {
        log("OAuthService.handleCallback › \(url)")
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let codeItem = components.queryItems?.first(where: { $0.name == "code" }),
            let code = codeItem.value, !code.isEmpty
        else {
            log("OAuthService.handleCallback › missing code")
            finish(success: false)
            return
        }
        // Validate state to prevent CSRF.
        let receivedState = components.queryItems?.first(where: { $0.name == "state" })?.value
        guard receivedState == pendingState else {
            log("OAuthService.handleCallback › state mismatch")
            finish(success: false)
            return
        }
        pendingState = nil
        exchangeCode(code)
    }

    // MARK: - Code exchange

    private func exchangeCode(_ code: String) {
        var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "redirect_uri": "runnerbar://oauth/callback"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        log("OAuthService.exchangeCode › POST access_token")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            if let error {
                log("OAuthService.exchangeCode › network error: \(error)")
                self.finish(success: false)
                return
            }
            guard
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let token = json["access_token"] as? String, !token.isEmpty
            else {
                log("OAuthService.exchangeCode › parse failed")
                self.finish(success: false)
                return
            }
            log("OAuthService.exchangeCode › token received, storing in Keychain")
            Keychain.save(token: token)
            self.finish(success: true)
        }.resume()
    }

    // MARK: - Finish

    private func finish(success: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onCompletion?(success)
            self?.onCompletion = nil
        }
    }

    // MARK: - Sign out

    /// Removes the stored token from the Keychain.
    func signOut() {
        Keychain.delete()
        log("OAuthService.signOut › token cleared")
    }

    // MARK: - Auth state

    /// Returns `true` if a Keychain token is present.
    var isSignedIn: Bool { Keychain.token() != nil }
}
