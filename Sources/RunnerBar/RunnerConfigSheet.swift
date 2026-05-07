import SwiftUI

// MARK: - RunnerConfigSheet

/// Phase 2: Inline sheet for editing a runner's labels and work folder.
/// Changes are applied immediately via `RunnerLifecycleService`.
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
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Work folder").font(.caption).foregroundColor(.secondary)
                TextField("e.g. _work", text: $workFolderText)
                    .textFieldStyle(.roundedBorder)
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
        let labels = labelsText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let folder = workFolderText.trimmingCharacters(in: .whitespaces)
        DispatchQueue.global(qos: .userInitiated).async {
            RunnerLifecycleService.shared.updateConfig(
                runner: runner,
                labels: labels,
                workFolder: folder.isEmpty ? "_work" : folder
            )
            DispatchQueue.main.async {
                isSaving = false
                isPresented = nil
                onSave()
            }
        }
    }
}
