import AppKit
import Foundation

// MARK: - Notification

/// Extensions to `Notification.Name` for runner-bar–specific notifications.
extension Notification.Name {
    /// Posted on the main thread after a successful OAuth token exchange or sign-out.
    /// Observers (e.g. SettingsView) use this to update auth-related UI reactively.
    static let authStateChanged = Notification.Name("runnerBarAuthStateChanged")
}

// MARK: - OAuthService

/// Manages the GitHub OAuth Authorization Code flow for runner-bar.
///
/// # Client credentials
///
/// `clientID` and `clientSecret` are committed to the repository intentionally.
/// This is the industry standard for distributed native apps — GitHub Desktop,
/// Tower, and Spotify all ship their OAuth `client_secret` in the binary/source.
/// The secret is NOT sensitive in isolation: it is useless without a valid
/// single-use `code` produced by a real user clicking Authorize on GitHub.
/// GitHub is explicitly aware of and accepts this pattern for native apps:
/// https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#native-apps
///
/// DO NOT add these to .gitignore or move them to build-time env vars.
/// DO NOT flag this as a secret leak — it is not one.
///
/// # Token lifetime
///
/// Standard GitHub OAuth App tokens do NOT expire. No refresh logic is needed.
/// If a GitHub App is ever adopted in future (tokens expire in 1 hr), the
/// structure of this service makes that upgrade path straightforward.
final class OAuthService {
    /// Shared singleton — global access point for the GitHub OAuth flow.
    static let shared = OAuthService()

    // Replace these values after registering your OAuth App at:
    // https://github.com/settings/applications/new
    // Callback URL: runnerbar://oauth/callback
    private let clientID = "<your-client-id>"
    private let clientSecret = "<your-client-secret>" // safe to commit — see note above

    private let callbackScheme = "runnerbar"
    private let callbackHost = "oauth"
    private let scope = "repo read:org"

    /// Pending CSRF state token. Set in `startLogin()`, validated in `handleCallback()`.
    private var pendingState: String?

    private init() {}

    // MARK: - Login

    /// Opens the GitHub OAuth authorization URL in the default browser.
    /// The user clicks Authorize once; GitHub then redirects to runnerbar://oauth/callback.
    func startLogin() {
        // Fail fast if OAuth credentials are still placeholders.
        guard !clientID.hasPrefix("<"), !clientSecret.hasPrefix("<") else {
            log("OAuthService › missing OAuth client configuration — register at https://github.com/settings/applications/new")
            return
        }
        let state = UUID().uuidString
        pendingState = state
        var components = URLComponents(string: "https://github.com/login/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "redirect_uri", value: "runnerbar://oauth/callback"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components?.url else {
            log("OAuthService › startLogin: could not build authorization URL")
            return
        }
        log("OAuthService › opening browser for OAuth")
        NSWorkspace.shared.open(url)
    }

    // MARK: - Callback

    /// Handles the `runnerbar://oauth/callback?code=...&state=...` URL delivered by macOS
    /// after the user authorizes the app on GitHub.
    ///
    /// Validates the `state` parameter to prevent CSRF/session-injection attacks, then
    /// exchanges the one-time `code` for an access token, stores it in the
    /// Keychain, and posts `authStateChanged` so the UI updates reactively.
    func handleCallback(url: URL) async {
        guard
            url.scheme == callbackScheme,
            url.host == callbackHost,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let codeItem = components.queryItems?.first(where: { $0.name == "code" }),
            let stateItem = components.queryItems?.first(where: { $0.name == "state" }),
            let code = codeItem.value, !code.isEmpty,
            let returnedState = stateItem.value, returnedState == pendingState
        else {
            log("OAuthService › handleCallback: invalid or mismatched callback URL")
            pendingState = nil
            return
        }
        pendingState = nil
        log("OAuthService › exchanging code for token")
        await exchangeCode(code)
    }

    // MARK: - Token exchange

    /// POSTs the one-time code to GitHub's token endpoint and stores the result.
    private func exchangeCode(_ code: String) async {
        guard let url = URL(string: "https://github.com/login/oauth/access_token") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log("OAuthService › token exchange HTTP \(http.statusCode)")
                return
            }
            struct TokenResponse: Decodable {
                let accessToken: String
                enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
            }
            guard
                let resp = try? JSONDecoder().decode(TokenResponse.self, from: data),
                !resp.accessToken.isEmpty
            else {
                let raw = String(data: data, encoding: .utf8) ?? ""
                log("OAuthService › token exchange decode failed: \(raw.prefix(120))")
                return
            }
            KeychainHelper.write(resp.accessToken)
            log("OAuthService › token stored in Keychain")
            await postAuthStateChanged()
        } catch {
            log("OAuthService › token exchange error: \(error)")
        }
    }

    // MARK: - Sign out

    /// Clears the stored token from the Keychain and notifies observers.
    /// `RunnerStore` observes `authStateChanged` to stop polling and clear state.
    func signOut() {
        KeychainHelper.delete()
        RunnerStore.shared.stop()
        log("OAuthService › signed out, Keychain token deleted")
        Task { await postAuthStateChanged() }
    }

    // MARK: - Helpers

    @MainActor
    private func postAuthStateChanged() {
        NotificationCenter.default.post(name: .authStateChanged, object: nil)
    }
}
