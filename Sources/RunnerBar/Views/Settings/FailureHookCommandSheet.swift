import AppKit
import SwiftUI

// MARK: - FailureHookCommandSheet
// #544: Sheet for editing the per-scope failure hook command.
// #546: Added Test button + $LOCAL_PATH token.
//
// Presented from ScopeDetailView when user taps the Command row.
// Uses TextEditor (tall, monospaced) with variable pill buttons that insert at cursor.

/// Sheet for editing the shell command run by `FailureHookRunner` when a workflow fails.
/// Provides a monospaced `TextEditor` and variable-insertion pill buttons.
struct FailureHookCommandSheet: View {
    let scope: String
    let onDismiss: () -> Void

    @State private var commandText: String = ""

    // $FAILURE_LOG is pre-resolved by FailureHookRunner in Swift before the command
    // reaches the shell — log content is single-quote-escaped so special characters
    // never break shell parsing. Wrap it in single quotes in your command.
    //
    // NOTE: This is the same constant as FailureHookRunner.defaultCommand.
    // If the user never saves, FailureHookRunner falls back to this value automatically.
    private static let exampleCommand = FailureHookRunner.defaultCommand

    init(scope: String, onDismiss: @escaping () -> Void) {
        self.scope = scope
        self.onDismiss = onDismiss
        let saved = ScopePreferencesStore.failureHookCommand(for: scope) ?? ""
        log("FailureHookCommandSheet \u{203a} init — scope=\(scope) savedCommand='\(saved)' isEmpty=\(saved.isEmpty)")
        _commandText = State(initialValue: saved.isEmpty ? Self.exampleCommand : saved)
        log("FailureHookCommandSheet \u{203a} init — commandText seeded with '\(saved.isEmpty ? "exampleCommand" : "savedCommand")'")
    }

    private let variables: [String] = [
        "$SCOPE", "$LOCAL_PATH", "$BRANCH", "$RUN_ID", "$COMMIT_SHA",
        "$WORKFLOW_NAME", "$FAILURE_LOG",
        "$RUN_LINK", "$COMMIT_LINK", "$BRANCH_LINK", "$REPO_LINK"
    ]

    /// Lays out the header, command editor, variable pills, and footer action buttons.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            editorSection
            pillSection
            footerSection
        }
        .frame(width: 440)
        .background(Color.rbSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Subviews

extension FailureHookCommandSheet {
    var headerSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Failure Hook Command")
                .font(.system(size: 13, weight: .semibold))
            Text("Called in your default shell when a run in this scope fails. Use '$FAILURE_LOG' to inline the log text — all tokens are resolved before the shell runs the command.")
                .font(.caption)
                .foregroundColor(Color.rbTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    var editorSection: some View {
        TextEditor(text: $commandText)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(Color.rbSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
            )
            .frame(minHeight: 160, idealHeight: 180)
            .padding(.horizontal, 16)
    }

    var pillSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Insert variable at cursor:")
                .font(.caption2)
                .foregroundColor(Color.rbTextTertiary)
            FlowLayout(spacing: 5) {
                ForEach(variables, id: \.self) { variable in
                    Button(action: { insertVariable(variable) }) {
                        Text(variable)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color.rbTextSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.rbSurfaceElevated)
                                    .overlay(RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    var footerSection: some View {
        HStack {
            Spacer()
            Button("Cancel") { onDismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.rbSurfaceElevated)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))
                )
            if !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: { testCommand() }) {
                    Label("Test", systemImage: "play.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color.rbAccent)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.rbSurfaceElevated)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.rbAccent.opacity(0.4), lineWidth: 0.5))
                )
                .help("Run this command in Terminal now")
            }
            Button("Save") { save() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.rbAccent))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }
}

// MARK: - Actions

extension FailureHookCommandSheet {
    /// Persists `commandText` to `ScopePreferencesStore` for this scope and dismisses the sheet.
    func save() {
        log("FailureHookCommandSheet \u{203a} save — scope=\(scope) commandText='\(commandText.prefix(200))'")
        ScopePreferencesStore.setFailureHookCommand(commandText, for: scope)
        log("FailureHookCommandSheet \u{203a} save — done, dismissing")
        onDismiss()
    }

    /// Resolves `$LOCAL_PATH` and `$SCOPE` in `commandText` and opens the result in Terminal for a dry run.
    func testCommand() {
        let localPath = ScopePreferencesStore.localRepoPath(for: scope) ?? ""
        let resolved = commandText
            .replacingOccurrences(of: "$LOCAL_PATH", with: localPath)
            .replacingOccurrences(of: "$SCOPE", with: scope)
        log("FailureHookCommandSheet \u{203a} testCommand — scope=\(scope) localPath='\(localPath)' resolved='\(resolved.prefix(200))'")
        TerminalLauncher.open(command: resolved)
    }

    /// Appends `variable` to `commandText`, separated by a space (or sets it directly if empty).
    func insertVariable(_ variable: String) {
        if commandText.isEmpty {
            commandText = variable
        } else {
            commandText += " " + variable
        }
    }
}

// MARK: - FlowLayout

/// A custom `Layout` that wraps child views into rows like a word-wrapped line of text.
/// Used to arrange variable-insertion pill buttons beneath the command editor.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    /// Calculates the total height required to fit all subviews within the proposed width.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
        return CGSize(width: width, height: y + rowH)
    }

    /// Places each subview left-to-right, wrapping to the next row when the available width is exceeded.
    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowH: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
    }
}
