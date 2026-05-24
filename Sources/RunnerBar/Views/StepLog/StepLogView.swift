// StepLogView.swift
// RunnerBar
import AppKit
import RunnerBarCore
import SwiftUI
// ╔════════════════════════════════════════════════════════════════════════════╗
// ║ ☹️ StepLogView — LAYOUT + SIZING CONTRACT ☹️                              ║
// ╠════════════════════════════════════════════════════════════════════════════╣
// ║ Navigation level 3 (PopoverMainView → JobDetailView → StepLogView).      ║
// ║                                                                            ║
// ║ LAYOUT RULES:                                                              ║
// ║ • Root: .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)     ║
// ║ • idealWidth: 480 hints SwiftUI's initial natural width measurement.      ║
// ║   NSHostingController reads idealWidth as preferredContentSize.width      ║
// ║   on the first layout pass (NSPanel architecture, not NSPopover).         ║
// ║   The panel then resizes to content-driven width via KVO on               ║
// ║   preferredContentSize (see AppDelegate.sizeObservation).                 ║
// ║ • Log content MUST be inside the ScrollView.                              ║
// ║ • Header MUST be outside the ScrollView (always visible, not scrolled).  ║
// ║ ❌ NEVER use .frame(maxWidth: .infinity, maxHeight: .infinity) — the      ║
// ║   maxHeight: .infinity corrupts fittingSize.width when NSHostingCon-      ║
// ║   troller measures the view during a panel resize cycle.                  ║
// ║ ❌ NEVER use GeometryReader — it always reports .infinity in this        ║
// ║   NSPanel context and will cause an infinite resize loop.                 ║
// ║ ❌ NEVER remove idealWidth: 480.                                           ║
// ╚════════════════════════════════════════════════════════════════════════════╝

// MARK: - StepLogView

// #445: Scaffold + header + empty/loading states
// #450: Full log display in monospaced ScrollView
// #461: Copy-log button added to header
// #487: Fetch-on-appear (async, global QoS) with progress + error states
// #556: Failure hook integration — trigger hook on step-log open if job failed
// #557: ANSI escape code stripping added to log display
// #568: Header redesign — job title row, step name below, status dot
// #591: Metrics stripped from header (now shown inline in runner rows)

/// Displays the log output for a single workflow step.
/// Fetches log content on appear, strips ANSI codes, and renders in a monospaced ScrollView.
struct StepLogView: View {
    /// The job being displayed.
    let job: ActiveJob
    /// The specific step whose log is shown.
    let step: JobStep
    /// Closure called when the user taps the back button.
    let onBack: () -> Void

    /// Raw log text fetched from the GitHub API.
    @State private var logText: String = ""
    /// Whether the log fetch is still in-flight.
    @State private var isLoading: Bool = true
    /// Non-nil when the fetch fails.
    @State private var errorMessage: String?

    // MARK: - Body

    /// Root layout: fixed-width header above a scrollable log area.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            logContent
        }
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear(perform: fetchLog)
    }

    // MARK: - Header

    /// Navigation bar showing a back button, the job name, step name, and a copy-log button.
    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Back").font(.caption)
                    }
                    .foregroundColor(Color.rbTextSecondary)
                }
                .buttonStyle(.plain)
                Spacer()
                LogCopyButton(
                    fetch: { completion in
                        if logText.isEmpty {
                            completion(nil)
                        } else {
                            completion(logText)
                        }
                    },
                    isDisabled: isLoading || logText.isEmpty
                )
            }
            HStack(spacing: 6) {
                statusDot
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(step.name)
                        .font(.system(size: 11))
                        .foregroundColor(Color.rbTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// Colored dot sized to the step's current conclusion/status.
    private var statusDot: some View {
        let color: Color
        switch step.conclusion?.rawValue ?? step.status.rawValue {
        case "success":    color = Color.rbSuccess
        case "failure":    color = Color.rbDanger
        case "in_progress": color = Color.rbWarning
        default:           color = Color.rbTextTertiary
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    // MARK: - Log content area

    /// Scrollable monospaced log body, or loading/error placeholder.
    @ViewBuilder
    private var logContent: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading log…")
                    .font(.caption)
                    .foregroundColor(Color.rbTextSecondary)
            }
            .padding(RBSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let err = errorMessage {
            Text(err)
                .font(.caption)
                .foregroundColor(Color.rbDanger)
                .padding(RBSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if logText.isEmpty {
            Text("No log output.")
                .font(.caption)
                .foregroundColor(Color.rbTextTertiary)
                .padding(RBSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                Text(logText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color.rbTextPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(RBSpacing.sm)
            }
        }
    }

    // MARK: - Fetch

    /// Fetches the step log from the GitHub API on a background thread, strips ANSI codes, and updates state.
    private func fetchLog() {
        guard let jobId = job.id as Int?,
              let stepNumber = step.number as Int?
        else {
            errorMessage = "Missing job ID or step number."
            isLoading = false
            return
        }

        guard let htmlUrl = job.htmlUrl,
              let url = URL(string: htmlUrl)
        else {
            errorMessage = "Cannot determine scope from job URL."
            isLoading = false
            return
        }

        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else {
            errorMessage = "Cannot parse owner/repo from URL."
            isLoading = false
            return
        }
        let scope = "\(parts[0])/\(parts[1])"

        DispatchQueue.global(qos: .userInitiated).async {
            let text = fetchStepLog(jobID: jobId, stepNumber: stepNumber, scope: scope)
            DispatchQueue.main.async {
                isLoading = false
                if let text {
                    logText = stripANSI(text)
                } else {
                    errorMessage = "Failed to load log."
                }
            }
        }
    }
}

// MARK: - ANSI stripping

/// Removes ANSI escape sequences (colour codes, cursor moves, etc.) from `text`.
private func stripANSI(_ text: String) -> String {
    let pattern = "\u{1b}(\\[[0-9;]*[A-Za-z]|\\][^\u{07}]*\u{07}|[^\\[\\]])"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
}
