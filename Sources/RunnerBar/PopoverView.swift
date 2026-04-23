import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: RunnerStoreObservable
    @State private var newScope = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Text("RunnerBar v0.1")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { RunnerStore.shared.fetch() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Runner list
            if store.runners.isEmpty {
                Text("No runners found")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.runners, id: \.id) { runner in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(dotColor(for: runner))
                            .frame(width: 8, height: 8)
                        Text(runner.name)
                            .font(.system(size: 13))
                        Spacer()
                        Text(runner.busy ? "active" : runner.status == "online" ? "idle" : "offline")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }

            Divider()

            // Scope management
            VStack(alignment: .leading, spacing: 4) {
                Text("Scopes")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                ForEach(ScopeStore.shared.scopes, id: \.self) { scope in
                    HStack {
                        Text(scope)
                            .font(.system(size: 12))
                        Spacer()
                        Button(action: {
                            ScopeStore.shared.remove(scope)
                            store.reload()
                        }) {
                            Image(systemName: "minus.circle")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }

                HStack {
                    TextField("owner/repo or org", text: $newScope)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { submitScope() }
                    Button(action: submitScope) {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(newScope.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            Divider()

            // Quit
            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack {
                    Image(systemName: "xmark.square")
                    Text("Quit")
                }
                .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    private func submitScope() {
        let trimmed = newScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ScopeStore.shared.add(trimmed)
        RunnerStore.shared.start()
        store.reload()
        newScope = ""
    }

    private func dotColor(for runner: Runner) -> Color {
        if runner.status != "online" { return .gray }
        return runner.busy ? .yellow : .green
    }
}

final class RunnerStoreObservable: ObservableObject {
    @Published var runners: [Runner] = []

    init() {
        RunnerStore.shared.onChange = { [weak self] in
            DispatchQueue.main.async {
                self?.runners = RunnerStore.shared.runners
            }
        }
        runners = RunnerStore.shared.runners
    }

    func reload() {
        runners = RunnerStore.shared.runners
        objectWillChange.send()
    }
}
