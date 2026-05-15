import SwiftUI

// MARK: - RemovalAlertModifier

/// `ViewModifier` that encapsulates the runner-removal confirmation alert.
/// Extracted from `SettingsView.body` to satisfy `function_body_length`
/// and `file_length` limits.
struct RemovalAlertModifier: ViewModifier {
    /// The alert title string.
    let title: String
    /// Controls whether the alert is presented.
    @Binding var isPresented: Bool
    /// Whether a GitHub token is available; changes the alert message.
    let isAuthenticated: Bool
    /// Called when the user taps Cancel.
    let onCancel: () -> Void
    /// Called when the user confirms removal.
    let onConfirm: () -> Void

    /// Wraps `content` with a runner-removal confirmation alert.
    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            Button("Cancel", role: .cancel) { onCancel() }
            Button("Remove", role: .destructive) { onConfirm() }
        } message: {
            if isAuthenticated {
                Text("This will run ./svc.sh uninstall and ./config.sh remove. "
                    + "A GitHub token is required for de-registration.")
            } else {
                Text("A GitHub token is required to de-register the runner from GitHub. "
                    + "Sign in via `gh auth login` or set GH_TOKEN, then try again.")
            }
        }
    }
}
