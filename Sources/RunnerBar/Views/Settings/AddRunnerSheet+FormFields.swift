// AddRunnerSheet+FormFields.swift
// RunnerBar

import AppKit
import SwiftUI

// swiftlint:disable:next missing_docs
extension AddRunnerSheet {

    // MARK: - Add New Form Body

    /// Form fields shown when the user selects the "Add new" mode:
    /// scope picker, repo/org selector, runner name, labels, and install path.
    @ViewBuilder
    var addNewFormBody: some View {
        Picker("Scope", selection: $scopeType) {
            ForEach(ScopeType.allCases) { s in Text(s.rawValue).tag(s) }
        }
        .pickerStyle(.segmented)

        if isLoadingScopes {
            HStack {
                ProgressView().scaleEffect(0.7)
                Text("Loading…").font(.caption).foregroundColor(.secondary)
            }
        } else if scopeType == .repo {
            selectorButton(
                label: "Repository",
                selection: selectedRepo,
                action: { showRepoSelector = true }
            )
            .sheet(isPresented: $showRepoSelector) {
                RepoSelectorSheet(
                    items: repos,
                    label: "Repository",
                    onDismiss: { showRepoSelector = false },
                    onSelect: { item in
                        selectedRepo = item
                    }
                )
            }
        } else {
            selectorButton(
                label: "Organisation",
                selection: selectedOrg,
                action: { showOrgSelector = true }
            )
            .sheet(isPresented: $showOrgSelector) {
                RepoSelectorSheet(
                    items: orgs,
                    label: "Organisation",
                    onDismiss: { showOrgSelector = false },
                    onSelect: { item in
                        selectedOrg = item
                    }
                )
            }
        }

        labeledField("Runner name", placeholder: "e.g. my-mac-runner", text: $runnerName)
        labeledField(
            "Labels (comma-separated)",
            placeholder: "e.g. self-hosted,macOS,arm64",
            text: $labelsText
        )

        VStack(alignment: .leading, spacing: 4) {
            Text("Runner install directory").font(.caption).foregroundColor(.secondary)
            TextField("", text: $installDir)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            Text(
                "Each runner needs its own unique folder. Use the runner name as the last path component, e.g. ~/actions-runner/my-runner."
            )
            .font(.caption2)
            .foregroundColor(.secondary)
            if dirAlreadyConfigured {
                Label(
                    "This folder already has a runner configured. Choose a different path.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundColor(.orange)
            }
        }

        if isRegistering && !registrationStep.isEmpty {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text(registrationStep).font(.caption).foregroundColor(.secondary)
            }
        }

        if let err = errorMessage {
            Text(err)
                .font(.caption).foregroundColor(.red)
                .padding(8)
                .background(Color.red.opacity(0.08))
                .cornerRadius(6)
        }

        HStack {
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .disabled(isRegistering)
            Button {
                Task { await register() }
            } label: {
                if isRegistering {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                        Text("Registering…")
                    }
                } else {
                    Text("Add new runner")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canRegister || isRegistering)
        }
    }

    // MARK: - Add Pre-Existing Form Body

    /// Form fields shown when the user selects the "Add pre-existing" mode:
    /// folder picker, detected runner name, and GitHub URL display/override.
    @ViewBuilder
    var addExistingFormBody: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Folder picker row
            VStack(alignment: .leading, spacing: 4) {
                Text("Runner install folder").font(.caption).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Text(existingDir.isEmpty ? "No folder selected" : existingDir)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(existingDir.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        pickExistingFolder()
                    } label: {
                        Text("Choose…")
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color(nsColor: .windowBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }

            // Detected fields (shown once a valid folder is picked)
            if !detectedName.isEmpty {
                labeledReadOnly("Runner name (detected)", value: detectedName)

                if detectedGitHubURL.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GitHub URL").font(.caption).foregroundColor(.secondary)
                        TextField("\(GitHubURIs.base)owner/repo", text: $githubURLOverride)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Text("The .runner file has no GitHub URL. Paste the repo or org URL above.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    labeledReadOnly("GitHub URL (detected)", value: detectedGitHubURL)
                }
            }

            // Error state
            if let err = existingError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(6)
            }

            // Duplicate warning
            if isDuplicate {
                Label(
                    "This runner is already tracked by RunnerBar.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundColor(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Import Runner", action: importExistingRunner)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
    }

    // MARK: - Sub-views

    /// Selector button that opens the searchable `RepoSelectorSheet`.
    ///
    /// Shows the current selection as the button label, or a "— select —" placeholder
    /// when nothing has been chosen. A hint is shown below when the list is empty.
    @ViewBuilder
    func selectorButton(label: String, selection: String,
                        action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Button(action: action) {
                HStack {
                    Text(selection.isEmpty ? "— select —" : selection)
                        .font(.system(size: 12))
                        .foregroundColor(selection.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            if selection.isEmpty {
                Text("No \(label.lowercased())s found. Sign in with GitHub or set GH_TOKEN / GITHUB_TOKEN.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    /// Renders a caption label above a `TextField` with rounded-border style.
    @ViewBuilder
    func labeledField(_ title: String, placeholder: String,
                      text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    /// Read-only monospaced display field used in the pre-existing form.
    @ViewBuilder
    func labeledReadOnly(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
    }

    // MARK: - Actions (Add pre-existing)

    /// Opens an `NSOpenPanel` as a sheet attached to the popover's own window.
    ///
    /// Uses `beginSheetModal(for:)` so the panel attaches as a child sheet and
    /// AppKit never treats clicks inside the panel as "outside clicks" that would
    /// dismiss the popover.
    func pickExistingFolder() {
        guard let window = hostWindow else {
            log("AddRunnerSheet › pickExistingFolder — ERROR: hostWindow nil, picker will not open")
            return
        }
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.message = "Select the runner install folder (must contain a .runner file)"
        openPanel.prompt = "Select"
        log("AddRunnerSheet › pickExistingFolder — calling beginSheetModal")
        openPanel.beginSheetModal(for: window) { response in
            log("AddRunnerSheet › pickExistingFolder — panel closed response=\(response.rawValue)")
            guard response == .OK, let url = openPanel.url else { return }
            handlePickedFolder(url)
        }
    }

    /// Validates the picked folder and populates the detected-runner state.
    func handlePickedFolder(_ url: URL) {
        resetExistingState()
        existingDir = url.path

        let runnerFileURL = url.appendingPathComponent(".runner")
        guard FileManager.default.fileExists(atPath: runnerFileURL.path) else {
            existingError = "No .runner file found in the selected folder. Is this a valid runner install directory?"
            return
        }

        guard let data = try? Data(contentsOf: runnerFileURL) else {
            existingError = "Could not read .runner file."
            return
        }

        struct RunnerJSON: Decodable {
            let gitHubUrl: String?
            let runnerName: String?
        }

        guard let json = try? JSONDecoder().decode(RunnerJSON.self, from: data) else {
            existingError = "Could not parse .runner file. It may be malformed."
            return
        }

        detectedName = json.runnerName ?? url.lastPathComponent
        detectedGitHubURL = json.gitHubUrl ?? ""
        isDuplicate = checkDuplicate(runnerName: detectedName)

        log("AddRunnerSheet › pre-existing: name=\(detectedName) url=\(detectedGitHubURL) duplicate=\(isDuplicate)")
    }

    /// Writes the LaunchAgent plist, registers with `LocalRunnerStore`, and dismisses the sheet.
    func importExistingRunner() {
        guard canImport else { return }

        let scope = effectiveGitHubURL
            .replacingOccurrences(of: GitHubURIs.base, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !scope.isEmpty else {
            existingError = "Could not derive a scope from the GitHub URL. Please check the URL."
            return
        }

        writeLaunchAgentPlist(
            scope: scope,
            runnerName: detectedName,
            workingDirectory: existingDir
        )
        LocalRunnerStore.shared.add(runnerName: detectedName, installPath: existingDir)

        isPresented = false
        onComplete()
    }
}
