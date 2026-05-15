// swiftlint:disable missing_docs
import SwiftUI

// MARK: - RunnerConfigSheet
struct RunnerConfigSheet: View {
    let runner: Runner
    @Environment(\.dismiss) private var dismiss
    @State private var url: String = ""
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
                Button("Save") { dismiss() }
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
// swiftlint:enable missing_docs
