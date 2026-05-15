import SwiftUI

// MARK: - RunnerConfigSheet
/// Sheet presented when the user taps "Configure" on a local runner row.
/// Allows editing the runner's registration URL and token.
struct RunnerConfigSheet: View {
    /// The runner being configured.
    let runner: Runner
    /// Dismiss action provided by the sheet presenter.
    @Environment(\.dismiss) private var dismiss
    /// Editable registration URL field.
    @State private var url: String = ""
    /// Editable registration token field.
    @State private var token: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure Runner")
                .font(.headline)
            Text(runner.name)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Divider()
            LabeledContent("Registration URL") {
                TextField("https://github.com/org/repo", text: $url)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Token") {
                SecureField("Registration token", text: $token)
                    .textFieldStyle(.roundedBorder)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    // Persist config — implementation in RunnerLifecycleService
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 360, minHeight: 220)
        .onAppear {
            url   = ""
            token = ""
        }
    }
}
