// AppDelegate+Notifications.swift
// RunnerBar

import AppKit

extension AppDelegate {

    // MARK: - OAuth URL callback

    /// Handles the OAuth callback URL (`runnerbar://oauth/…`) delivered by the OS
    /// after the user authorises the GitHub OAuth flow in the browser.
    /// - Parameters:
    ///   - _: The NSApplication instance (unused).
    ///   - urls: The array of URLs opened by the OS; only the first matching OAuth URL is consumed.
    func application(_ _: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: {
            $0.scheme == GitHubConstants.oauthScheme && $0.host == GitHubConstants.oauthHost
        }) else { return }
        OAuthService.shared.handleCallback(url)
    }
}
