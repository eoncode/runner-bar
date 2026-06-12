// AppDelegate+Polling.swift
// RunnerBar

import Foundation

/// AppDelegate extension managing the OAuth sign-out subscription and poll-loop coordination.
extension AppDelegate {

    // MARK: - Sign-out subscription

    /// Restarts the poll loop when the user signs out of OAuth so that
    /// `githubToken()` re-resolves to `GH_TOKEN` / `GITHUB_TOKEN` env vars
    /// on the very next fetch cycle.
    ///
    /// ## Why this lives here and not in SettingsView
    /// `SettingsView`'s `signOutTask` is stored in `@State` and is
    /// only alive while Settings is visible. `AppDelegate` is a true singleton
    /// for the app's lifetime, so this task is always active.
    ///
    /// ## What was broken (regression from PR #1138)
    /// Before #1138, polling was driven by `Timer + scheduleTimer()`. After
    /// sign-out the timer fired, `fetch()` ran, `githubToken()` found the
    /// cache cleared, and naturally fell through to env-var tokens.
    /// #1138 replaced the timer with a `pollTask: Task` that loops on
    /// `Task.sleep` — it never calls `start()` again, so the token fallback
    /// only works if `start()` is explicitly invoked after sign-out.
    func setupSignOutSubscription() {
        signOutTask = Task { [weak self] in
            for await _ in OAuthService.shared.makeSignOutStream() {
                log("AppDelegate › didSignOut — restarting poll loop for env-token fallback")
                await self?.runnerStore.start()
            }
        }
    }
}
