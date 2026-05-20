import AppKit
import SwiftUI

// MARK: - FailureHookCommandSheet
// #544: Sheet for editing the per-scope failure hook command.
// #546: Added Test button + $LOCAL_PATH token.
//
// Presented from ScopeDetailView when user taps the Command row.
// Uses TextEditor (tall, monospaced) with variable pill buttons that insert at cursor.

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
        let saved = ScopeSettingsStore.failureHookCommand(for: scope) ?? ""
        log("FailureHookCommandSheet › init — scope=\(scope) savedCommand='\(saved)' isEmpty=\(saved.isEmpty)")
        _commandText = State(initialValue: saved.isEmpty ? Self.exampleCommand : saved)
        log("FailureHookCommandSheet › init — commandText seeded with '\(saved.isEmpty ? "exampleCommand" : "savedCommand")'")
    }

    private let variables: [String] = [
        "$SCOPE", "$LOCAL_PATH", "$BRANCH", "$RUN_ID", "$COMMIT_SHA",
        "$WORKFLOW_NAME", "$FAILURE_LOG",
        "$RUN_LINK", "$COMMIT_LINK", "$BRANCH_LINK", "$REPO_LINK"
    ]

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
    func save() {
        log("FailureHookCommandSheet › save — scope=\(scope) commandText='\(commandText.prefix(200))'")
        ScopeSettingsStore.setFailureHookCommand(commandText, for: scope)
        log("FailureHookCommandSheet › save — done, dismissing")
        onDismiss()
    }

    func testCommand() {
        let localPath = ScopeSettingsStore.localRepoPath(for: scope) ?? ""
        let resolved = commandText
            .replacingOccurrences(of: "$LOCAL_PATH", with: localPath)
            .replacingOccurrences(of: "$SCOPE", with: scope)
        log("FailureHookCommandSheet › testCommand — scope=\(scope) localPath='\(localPath)' resolved='\(resolved.prefix(200))'")
        TerminalLauncher.open(command: resolved)
    }

    func insertVariable(_ variable: String) {
        if commandText.isEmpty {
            commandText = variable
        } else {
            commandText += " " + variable
        }
    }
}

// MARK: - FlowLayout
// Simple wrapping HStack for variable pills.

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
    }
}
