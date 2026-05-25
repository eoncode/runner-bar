// ScopeDetailView.swift
// RunnerBar
import RunnerBarCore
import SwiftUI

// MARK: - ScopeDetailView

// Navigation level: SettingsView (scope row tap) → ScopeDetailView
//
// #499: Nav shell + wiring
// #513: Simplified — alias, polling, notifications sections removed.
//       Enable toggle moved from header into its own Monitoring section.
//       Monitoring row removed from Scope Info card.
// #539: Layout improvements -- section labels, card structure aligned with spec.
// #544: Failure Hook section added between Monitoring and Danger Zone.
// #546: Local Path row — inline editing, NSOpenPanel folder picker, tilde pre-fill.
//       Popover is closed before NSOpenPanel runs and reopened after, so the
//       panel is never obscured by the popover.
// #559: Failure Hook section hidden for org scopes — only shown for repo scopes.
// #560: Branch selector row added to Failure Hook section.
/// Detail settings screen for a single scope (org or repo).
/// Rendered when the user taps a scope row in `SettingsView`.
struct ScopeDetailView: View {
    /// The scope entry being inspected. Treated as a snapshot; live state is
    /// re-read from `ScopeStore` via `liveEntry`.
    let scopeEntry: ScopeEntry
    /// Callback invoked when the user taps the back button to return to
    /// `SettingsView`.
    let onBack: () -> Void

    /// Observed store that drives live `isEnabled` state without requiring a re-init.
    @ObservedObject private var scopeStore = ScopeStore.shared
    /// Controls presentation of the `FailureHookCommandSheet`.
    @State private var showHookSheet = false
    /// Controls presentation of the `BranchSelectorSheet`.
    @State private var showBranchSheet = false
    /// Mirrors `ScopePreferencesStore.failureHookEnabled` for optimistic toggle updates.
    @State private var hookEnabled: Bool
    /// Mirrors `ScopePreferencesStore.failureHookBranch`; `nil` means all branches.
    @State private var hookBranch: String?
    /// Mirrors `ScopePreferencesStore.localRepoPath`; empty string means unset.
    @State private var localRepoPath: String
    /// Whether the local-path row is currently in inline-edit mode.
    @State private var isEditingPath = false

    /// Creates the view, seeding `@State` values from `ScopePreferencesStore`
    /// so they reflect persisted user preferences on first render.
    init(scopeEntry: ScopeEntry, onBack: @escaping () -> Void) {
        self.scopeEntry = scopeEntry
        self.onBack = onBack
        _hookEnabled = State(initialValue: ScopePreferencesStore.failureHookEnabled(for: scopeEntry.scope))
        _hookBranch = State(initialValue: ScopePreferencesStore.failureHookBranch(for: scopeEntry.scope))
        _localRepoPath = State(initialValue: ScopePreferencesStore.localRepoPath(for: scopeEntry.scope) ?? "")
    }

    /// The up-to-date entry from `ScopeStore`, or `nil` if the scope has been
    /// removed since this view was created.
    private var liveEntry: ScopeEntry? {
        scopeStore.entries.first(where: { $0.id == scopeEntry.id })
    }
    /// Whether monitoring is currently enabled for this scope.
    private var isEnabled: Bool { liveEntry?.isEnabled ?? scopeEntry.isEnabled }
    /// The raw scope string (e.g. `"owner/repo"` or `"owner"`).
    private var scope: String { scopeEntry.scope }
    /// `true` when the scope string contains a slash, indicating a repository scope.
    private var isRepo: Bool { scope.contains("/") }
    /// The persisted failure-hook terminal command for this scope, if set.
    private var hookCommand: String? { ScopePreferencesStore.failureHookCommand(for: scope) }
    /// The GitHub web URL for this scope.
    private var gitHURL: URL? { URL(string: "https://github.com/\(scope)") }

    /// Root layout: navigation bar, divider, and scrollable section stack.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    infoSection
                    monitoringSection
                    if isRepo { failureHookSection }
                    dangerSection
                }
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(idealWidth: 480, maxWidth: .infinity)
        .sheet(isPresented: $showHookSheet) {
            FailureHookCommandSheet(scope: scope) { showHookSheet = false }
        }
        .sheet(isPresented: $showBranchSheet) {
            BranchSelectorSheet(
                scope: scope,
                onDismiss: { showBranchSheet = false },
                onSelect: { chosen in
                    hookBranch = chosen
                    ScopePreferencesStore.setFailureHookBranch(chosen, for: scope)
                    showBranchSheet = false
                }
            )
        }
    }
}

// MARK: - Sections
extension ScopeDetailView {
    /// Top navigation bar showing a back button and the scope display name.
    var headerBar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.caption)
                    Text("Settings").font(.caption)
                }
                .foregroundColor(Color.rbTextSecondary)
                .fixedSize()
            }
            .buttonStyle(.plain)
            Spacer()
            HStack(spacing: 6) {
                Text(isRepo ? "Repo" : "Org")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.rbSurfaceElevated))
                    .overlay(Capsule().strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))
                Text(ScopePreferencesStore.displayName(for: scope))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// Card section displaying read-only scope metadata.
    var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Scope Info")
            infoCard {
                infoRow(label: "Scope", value: scope, copyable: true)
                Divider().padding(.leading, RBSpacing.md)
                infoRow(label: "Type", value: isRepo ? "Repository" : "Organisation")
                if let url = gitHURL {
                    Divider().padding(.leading, RBSpacing.md)
                    HStack(alignment: .top, spacing: 8) {
                        Text("GitHub")
                            .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                            .frame(width: 100, alignment: .leading).fixedSize()
                        Button(action: { NSWorkspace.shared.open(url) }) {
                            HStack(spacing: 4) {
                                Text("Open on GitHub")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.rbAccent)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color.rbAccent)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(url.absoluteString)
                        Spacer()
                    }
                    .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                }
            }
        }
    }

    /// Card section with a toggle to enable or disable polling for this scope.
    var monitoringSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Monitoring")
            infoCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Monitor this scope")
                            .font(.system(size: 12, weight: .medium))
                        Text(isEnabled
                             ? "RunnerBar actively polls this scope for runner status."
                             : "Polling is paused. No runner data will be fetched for this scope.")
                            .font(.caption2)
                            .foregroundColor(Color.rbTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { isEnabled },
                        set: { ScopeStore.shared.setEnabled(scopeEntry.id, $0); RunnerStore.shared.start() }
                    ))
                    .toggleStyle(.switch)
                    .tint(Color.rbSuccess)
                    .labelsHidden()
                    .help(isEnabled ? "Pause monitoring this scope" : "Resume monitoring")
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 10)
            }
        }
    }

    /// Card section for configuring the failure-hook command.
    /// Only rendered for repository scopes (`isRepo == true`).
    var failureHookSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Failure Hook")
            infoCard {
                hookToggleRow
                Divider().padding(.leading, RBSpacing.md)
                branchRow
                Divider().padding(.leading, RBSpacing.md)
                localPathRow
                Divider().padding(.leading, RBSpacing.md)
                commandRow
            }
        }
    }

    /// Card section with a destructive "Remove scope" action.
    var dangerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Danger Zone")
            infoCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remove scope")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.rbDanger)
                        Text("Stops monitoring this scope. Runners already discovered are not affected.")
                            .font(.caption2).foregroundColor(Color.rbTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(action: removeScope) {
                        Text("Remove").font(.caption2).foregroundColor(Color.rbDanger)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 10)
            }
        }
    }
}

// MARK: - Failure Hook Rows
extension ScopeDetailView {
    /// Toggle row enabling or disabling the failure-hook for this scope.
    var hookToggleRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Call this terminal call on failure detection")
                    .font(.system(size: 12, weight: .medium))
                Text("This will call terminal with a call of your choosing. Can be used for AI auto-recovery.")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { hookEnabled },
                set: { newVal in
                    hookEnabled = newVal
                    ScopePreferencesStore.setFailureHookEnabled(newVal, for: scope)
                }
            ))
            .toggleStyle(.switch)
            .tint(Color.rbSuccess)
            .labelsHidden()
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 10)
    }

    /// Row for selecting the branch filter applied by the failure hook.
    var branchRow: some View {
        Button(action: { showBranchSheet = true }) {
            HStack(spacing: 8) {
                Text("Branch")
                    .font(.system(size: 12))
                    .foregroundColor(Color.rbTextSecondary)
                    .frame(width: 100, alignment: .leading)
                    .fixedSize()
                if let branch = hookBranch {
                    Text(branch)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.rbTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: clearBranchFilter) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color.rbTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear branch filter")
                } else {
                    Text("All branches")
                        .font(.system(size: 11))
                        .foregroundColor(Color.rbTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(Color.rbTextTertiary)
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Row for setting the local repository path used by the failure hook.
    var localPathRow: some View {
        HStack(spacing: 8) {
            Text("Local Path")
                .font(.system(size: 12))
                .foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading)
                .fixedSize()
            if isEditingPath {
                TextField("~/code/org/repo", text: $localRepoPath)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.plain)
                    .foregroundColor(Color.rbTextPrimary)
                    .frame(maxWidth: .infinity)
                    .onSubmit { commitLocalPath() }
                Button("Done") { commitLocalPath() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.rbAccent)
            } else {
                Button(action: { startEditingPath() }) {
                    Text(localRepoPath.isEmpty ? "Tap to set path…" : localRepoPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(localRepoPath.isEmpty ? Color.rbTextTertiary : Color.rbTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Button(action: { openFolderPicker() }) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(Color.rbTextSecondary)
                }
                .buttonStyle(.plain)
                .help("Browse for folder…")
                if !localRepoPath.isEmpty {
                    Button(action: {
                        localRepoPath = ""
                        ScopePreferencesStore.setLocalRepoPath(nil, for: scope)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color.rbTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear local path")
                }
            }
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 9)
    }

    /// Row for configuring the hook command; opens `FailureHookCommandSheet` on tap.
    var commandRow: some View {
        Button(action: { showHookSheet = true }) {
            HStack(spacing: 8) {
                Text("Command")
                    .font(.system(size: 12))
                    .foregroundColor(Color.rbTextSecondary)
                    .frame(width: 100, alignment: .leading)
                    .fixedSize()
                if let cmd = hookCommand, !cmd.isEmpty {
                    Text(cmd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.rbTextPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Tap to set a command…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.rbTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(Color.rbTextTertiary)
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Actions
extension ScopeDetailView {
    /// Enters inline editing mode for the local-path field, pre-filling `~/` if the field is empty.
    func startEditingPath() {
        if localRepoPath.isEmpty { localRepoPath = "~/" }
        isEditingPath = true
    }

    /// Commits the edited local path, strips the bare `~/` placeholder, and persists the value.
    func commitLocalPath() {
        isEditingPath = false
        let trimmed = localRepoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = (trimmed == "~/") ? "" : trimmed
        localRepoPath = cleaned
        ScopePreferencesStore.setLocalRepoPath(cleaned.isEmpty ? nil : cleaned, for: scope)
    }

    /// Clears the branch filter for the failure hook and persists the change.
    func clearBranchFilter() {
        hookBranch = nil
        ScopePreferencesStore.setFailureHookBranch(nil, for: scope)
    }

    /// Presents an `NSOpenPanel` to let the user pick the local repository folder.
    /// The panel closes before presenting to avoid being obscured by the popover.
    func openFolderPicker() {
        let appDelegate = NSApp.delegate as? AppDelegate
        appDelegate?.closePanel()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose the local folder for \(scope)"
        if !localRepoPath.isEmpty {
            let expanded = NSString(string: localRepoPath).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            if response == .OK, let url = panel.url {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let abs = url.path
                let tilde = abs.hasPrefix(home) ? "~/" + abs.dropFirst(home.count + 1) : abs
                localRepoPath = tilde
                ScopePreferencesStore.setLocalRepoPath(tilde, for: scope)
            }
            appDelegate?.openPanel()
        }
    }

    /// Removes the scope from `ScopeStore`, cleans up preferences, restarts polling, and navigates back.
    func removeScope() {
        ScopePreferencesStore.cleanUp(scope: scope)
        ScopeStore.shared.remove(id: scopeEntry.id)
        RunnerStore.shared.start()
        onBack()
    }
}

// MARK: - Sub-view helpers
extension ScopeDetailView {
    /// Renders a styled section-header label above a settings card group.
    func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 4)
    }

    /// Wraps `content` in the standard rounded-card background used across all settings sections.
    func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: RBRadius.small)
                .fill(Color.rbSurfaceElevated)
                .overlay(RoundedRectangle(cornerRadius: RBRadius.small)
                    .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))
        )
        .padding(.horizontal, RBSpacing.md)
        .padding(.bottom, 8)
    }

    /// Renders a label–value row inside an info card, with an optional clipboard-copy button.
    func infoRow(label: String, value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading).fixedSize()
            Text(value)
                .font(.system(size: 12, design: .monospaced)).foregroundColor(Color.rbTextPrimary)
                .lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copyable {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(Color.rbTextTertiary)
                }
                .buttonStyle(.plain).help("Copy to clipboard")
            }
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
    }
}
