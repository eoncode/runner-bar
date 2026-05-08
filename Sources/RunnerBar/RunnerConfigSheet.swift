import SwiftUI

// MARK: - RunnerConfigSheet

/// Phase 2: Inline sheet for editing a runner's labels and work folder.
/// Changes are written to the `.runner` JSON file via `RunnerLifecycleService`.
/// The runner agent caches config in memory — changes take effect after the
/// next runner restart.
struct RunnerConfigSheet: View {
    /// The runner whose configuration is being edited.
    let runner: RunnerModel
    /// Binding to the runner currently being configured; set to `nil` to dismiss.
    @Binding var isPresented: RunnerModel?
    /// Called after a successful save so the caller can re-scan.
    let onSave: () -> Void

    @State private var labelsText: String
    @State private var workFolderText: String
    @State private var isSaving = false
    /// Non-nil when `updateConfig` returns `false`; shown as an inline error.
    @State private var errorMessage: String?

    init(runner: RunnerModel, isPresented: Binding<RunnerModel?>, onSave: @escaping () -> Void) {
        self.runner = runner
        self._isPresented = isPresented
        self.onSave = onSave
        self._labelsText = State(initialValue: runner.labels.joined(separator: ", "))
        self._workFolderText = State(initialValue: runner.workFolder ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure \"\(runner.runnerName)\"")
                .font(.headline)
                .padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text("Labels (comma-separated)").font(.caption).foregroundColor(.secondary)
                TextField("e.g. self-hosted, macOS, arm64", text: $labelsText)
                    .textFieldStyle(.roundedBorder)
                // Labels are written to .runner JSON. The scanner reads systemLabels
                // (not customLabels) on the next scan, so the labels list shown in
                // Settings may not reflect these changes until the runner is restarted
                // and re-scanned with the updated agent config.
                Text("Changes take effect after the next runner restart.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Work folder").font(.caption).foregroundColor(.secondary)
                TextField("e.g. _work", text: $workFolderText)
                    .textFieldStyle(.roundedBorder)
            }
            if let msg = errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            HStack {
                Spacer()
                Button(action: { isPresented = nil }, label: { Text("Cancel") })
                    .keyboardShortcut(.cancelAction)
                Button(action: saveConfig, label: {
                    if isSaving {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Text("Save")
                    }
                })
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func saveConfig() {
        isSaving = true
        errorMessage = nil
        let labels = labelsText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let folder = workFolderText.trimmingCharacters(in: .whitespaces)
        DispatchQueue.global(qos: .userInitiated).async {
            let succeeded = RunnerLifecycleService.shared.updateConfig(
                runner: runner,
                labels: labels,
                workFolder: folder.isEmpty ? "_work" : folder
            )
            DispatchQueue.main.async {
                isSaving = false
                if succeeded {
                    isPresented = nil
                    onSave()
                } else {
                    errorMessage = "Failed to save — check that the runner's .runner file exists and is writable."
                }
            }
        }
    }
}
