import SwiftUI

// MARK: - AddRunnerSheet

/// Sheet for registering a new self-hosted runner with a GitHub repo or org.
struct AddRunnerSheet: View {

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    /// The GitHub scope (owner/repo or org) to register the runner under.
    @State private var scope: String = ""
    /// Optional runner label the user wants to assign.
    @State private var label: String = ""
    /// True while the registration network call is in-flight.
    @State private var isRegistering = false
    /// Holds an error string to display if registration fails.
    @State private var errorMessage: String?
    /// True once registration completes successfully.
    @State private var didSucceed = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Runner")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Scope (owner/repo or org)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g. myorg/myrepo", text: $scope)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Label (optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g. self-hosted, macOS", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if didSucceed {
                Text("Runner registered successfully.")
                    .font(.caption)
                    .foregroundColor(.green)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { register() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(scope.trimmingCharacters(in: .whitespaces).isEmpty || isRegistering)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .overlay {
            if isRegistering {
                ProgressView()
            }
        }
    }

    // MARK: - Registration

    private func register() {
        isRegistering = true
        errorMessage = nil
        didSucceed = false
        let trimmedScope = scope.trimmingCharacters(in: .whitespaces)
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        DispatchQueue.global(qos: .userInitiated).async {
            // Build args: pass label only when non-empty
            var args = ["--scope", trimmedScope]
            if !trimmedLabel.isEmpty {
                args += ["--label", trimmedLabel]
            }
            let result = shell(
                "/opt/homebrew/bin/gh runner register " + args.map { "'\($0)'" }.joined(separator: " "),
                timeout: 60
            )
            DispatchQueue.main.async {
                isRegistering = false
                if result.lowercased().contains("error") || result.lowercased().contains("failed") {
                    errorMessage = result.isEmpty ? "Unknown error" : result
                } else {
                    didSucceed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        dismiss()
                    }
                }
            }
        }
    }
}
