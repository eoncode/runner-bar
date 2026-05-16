// swiftlint:disable all
import SwiftUI

struct AddRunnerSheet: View {
    @EnvironmentObject var store: RunnerStoreObservable
    @Environment(\.dismiss) private var dismiss
    @State private var org: String = ""
    @State private var token: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Runner Scope").font(.headline)
            Divider()
            LabeledContent("Organisation / Repo") {
                TextField("owner/repo or owner", text: $org).textFieldStyle(.roundedBorder)
            }
            LabeledContent("GitHub Token") {
                SecureField("ghp_…", text: $token).textFieldStyle(.roundedBorder)
            }
            if let err = errorMessage {
                Text(err).font(.caption).foregroundColor(.red)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { addScope() }
                    .buttonStyle(.borderedProminent)
                    .disabled(org.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
            }
        }
        .padding()
        .frame(minWidth: 360, minHeight: 200)
    }

    private func addScope() {
        let trimmed = org.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let valid = validateScope(trimmed, token: token)
            DispatchQueue.main.async {
                isLoading = false
                if valid {
                    ScopeStore.shared.add(trimmed)
                    dismiss()
                } else {
                    errorMessage = "Could not validate scope. Check org/repo and token."
                }
            }
        }
    }
}

func validateScope(_ scope: String, token: String) -> Bool {
    let path = scope.contains("/") ? "repos/\(scope)" : "orgs/\(scope)"
    return ghAPI(path) != nil
}
