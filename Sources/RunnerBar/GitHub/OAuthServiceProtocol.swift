// OAuthServiceProtocol.swift
// RunnerBar
import Foundation

// MARK: - OAuthServiceProtocol

/// Abstraction over the GitHub OAuth Authorization Code flow.
///
/// `@MainActor` isolation mirrors the concrete `OAuthService` — all methods are
/// serialised on the main thread because:
/// - `handleCallback(_:)` is delivered by `AppDelegate.application(_:open:)` on the main thread.
/// - `onCompletion` is consumed by SwiftUI views (`SettingsView`).
/// - `makeSignOutStream()` is consumed by `AppDelegate.setupSignOutSubscription()`,
///   which runs on `@MainActor`.
///
/// `AnyObject` constraint is required because `onCompletion` is a settable `var`.
/// Mutating stored properties requires reference semantics — this protocol cannot
/// be adopted by a `struct`.
///
/// ## Production usage
/// ```swift
/// let oauthService: any OAuthServiceProtocol = OAuthService()
/// ```
///
/// ## Test double
/// ```swift
/// @MainActor
/// final class StubOAuthService: OAuthServiceProtocol {
///     var onCompletion: (@MainActor (Bool) -> Void)?
///     func signIn() {}
///     func signOut() {}
///     func handleCallback(_ url: URL) {}
///     func makeSignOutStream() -> AsyncStream<Void> { AsyncStream { _ in } }
/// }
/// ```
@MainActor
protocol OAuthServiceProtocol: AnyObject {
    /// Called on the main thread after sign-in completes. `true` = success.
    /// Register once in `SettingsView.onAppearAction` — do NOT re-assign in `signIn()`.
    /// The closure itself is `@MainActor`-isolated — conformers must invoke it on the main actor.
    var onCompletion: (@MainActor (Bool) -> Void)? { get set }

    /// Opens the GitHub OAuth authorization page in the default browser to begin sign-in.
    func signIn()

    /// Clears the stored token and emits a sign-out event to all stream consumers.
    func signOut()

    /// Handles the OAuth redirect URL from the OS, verifying the CSRF state nonce
    /// and exchanging the authorization code for an access token.
    func handleCallback(_ url: URL)

    /// Returns a new `AsyncStream<Void>` that fires once per `signOut()` call.
    /// Each call site must request its own stream; events are multicasted across all active streams.
    func makeSignOutStream() -> AsyncStream<Void>
}
