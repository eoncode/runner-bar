import SwiftUI

// MARK: - ScopeType

private enum ScopeType: String, CaseIterable, Identifiable {
    case org  = "Organisation"
    case repo = "Repository"
    var id: String { rawValue }
}

// MARK: - AddScopeSheet

/// Modal sheet for adding a new remote runner scope (org or repo).
///
/// Mirrors `AddRunnerSheet` in structure: segmented type toggle at the top,
/// a `Picker` when authenticated (populated from the GitHub API) with a plain
/// `TextField` fallback, and Cancel / Add buttons at the bottom.
///
/// On confirmation calls `ScopeStore.shared.add(_:)` + `RunnerStore.shared.start()`.
struct AddScopeSheet: View {
    @Binding var isPresented: Bool

    @State private var scopeType: ScopeType = .org
    @State private var selectedScope: String = ""
    @State private var manualScope: String = ""
    @State private var orgs: [String] = []
    @State private var repos: [String] = []
    @State private var isFetching = false
    @State private var errorMessage: String?
    @State private var usePicker = false

    private var pickerItems: [String] {
        scopeType == .org ? orgs : repos
    }

    private var effectiveScope: String {
        usePicker ? selectedScope : manualScope.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool { !effectiveScope.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ─────────────────────────────────────────────────────
            Text("Add remote scope")
                .font(.headline)
                .padding(.horizontal, RBSpacing.md)
                .padding(.top, RBSpacing.md)
                .padding(.bottom, RBSpacing.sm)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: RBSpacing.md) {

                    // ── Type toggle ──────────────────────────────────────────
                    Picker("", selection: $scopeType) {
                        ForEach(ScopeType.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: scopeType) { _ in selectedScope = pickerItems.first ?? "" }

                    // ── Scope picker / text field ────────────────────────────
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scopeType == .org ? "Organisation" : "Repository")
                            .font(.caption)
                            .foregroundColor(Color.rbTextSecondary)

                        if isFetching {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.7)
                                Text("Fetching from GitHub…")
                                    .font(.caption)
                                    .foregroundColor(Color.rbTextSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                        } else if usePicker && !pickerItems.isEmpty {
                            Picker("", selection: $selectedScope) {
                                ForEach(pickerItems, id: \.self) { item in
                                    Text(item).tag(item)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        } else {
                            TextField(
                                scopeType == .org ? "e.g. myorg" : "e.g. myorg/myrepo",
                                text: $manualScope
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        }

                        if let err = errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundColor(Color.rbDanger)
                        }
                    }

                    // ── Helper caption ───────────────────────────────────────
                    Text(scopeType == .org
                         ? "Monitors all runners in the organisation."
                         : "Monitors runners registered to this repository.")
                    .font(.caption)
                    .foregroundColor(Color.rbTextSecondary)
                }
                .padding(RBSpacing.md)
            }

            Divider()

            // ── Button row ─────────────────────────────────────────────────
            HStack {
                // Proper dismiss button — no async machinery needed for sheet dismissal.
                Button(action: { isPresented = false }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                        Text("Cancel")
                            .font(.caption)
                            .fixedSize()
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: confirmAdd) {
                    Text("Add Scope")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
            }
            .padding(.horizontal, RBSpacing.md)
            .padding(.vertical, RBSpacing.sm)
        }
        .frame(width: 420)
        .onAppear(perform: fetchScopeOptions)
    }

    // MARK: - Actions

    private func fetchScopeOptions() {
        guard githubToken() != nil else {
            log("AddScopeSheet › no token — falling back to text field")
            usePicker = false
            return
        }
        isFetching = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let fetchedOrgs  = fetchUserOrgs()
            let fetchedRepos = fetchUserRepos()
            DispatchQueue.main.async {
                isFetching = false
                if fetchedOrgs.isEmpty && fetchedRepos.isEmpty {
                    log("AddScopeSheet › fetch returned no orgs or repos — using text field")
                    usePicker = false
                    errorMessage = "Could not load orgs/repos. Enter manually."
                } else {
                    orgs  = fetchedOrgs
                    repos = fetchedRepos
                    usePicker = true
                    selectedScope = pickerItems.first ?? ""
                    log("AddScopeSheet › loaded orgs=\(orgs.count) repos=\(repos.count)")
                }
            }
        }
    }

    private func confirmAdd() {
        let scope = effectiveScope
        guard !scope.isEmpty else { return }
        ScopeStore.shared.add(scope)
        RunnerStore.shared.start()
        log("AddScopeSheet › added scope: \(scope)")
        isPresented = false
    }
}
