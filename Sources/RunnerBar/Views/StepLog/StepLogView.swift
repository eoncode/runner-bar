// StepLogView.swift
// RunnerBar
import AppKit
import RunnerBarCore
import SwiftUI
// \u{2554}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2557}
// \u{2551} \u{2639}\u{fe0f} StepLogView \u{2014} LAYOUT + SIZING CONTRACT \u{2639}\u{fe0f}                              \u{2551}
// \u{2560}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2563}
// \u{2551} Navigation level 3 (PopoverMainView \u{2192} JobDetailView \u{2192} StepLogView).      \u{2551}
// \u{2551}                                                                            \u{2551}
// \u{2551} LAYOUT RULES:                                                              \u{2551}
// \u{2551} \u{2022} Root: .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)     \u{2551}
// \u{2551} \u{2022} idealWidth: 480 hints SwiftUI's initial natural width measurement.      \u{2551}
// \u{2551}   NSHostingController reads idealWidth as preferredContentSize.width      \u{2551}
// \u{2551}   on the first layout pass (NSPanel architecture, not NSPopover).         \u{2551}
// \u{2551}   The panel then resizes to content-driven width via KVO on               \u{2551}
// \u{2551}   preferredContentSize (see AppDelegate.sizeObservation).                 \u{2551}
// \u{2551} \u{2022} Log content MUST be inside the ScrollView.                              \u{2551}
// \u{2551} \u{2022} Header MUST be outside the ScrollView (always visible, not scrolled).  \u{2551}
// \u{2551} \u{274c} NEVER use .frame(maxWidth: .infinity, maxHeight: .infinity) \u{2014} the      \u{2551}
// \u{2551}   maxHeight: .infinity corrupts fittingSize.width when NSHostingCon-      \u{2551}
// \u{2551}   troller measures the view during a panel resize cycle.                  \u{2551}
// \u{2551} \u{274c} NEVER use GeometryReader \u{2014} it always reports .infinity in this        \u{2551}
// \u{2551}   NSPanel context and will cause an infinite resize loop.                 \u{2551}
// \u{2551} \u{274c} NEVER remove idealWidth: 480.                                           \u{2551}
// \u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d}

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
        switch step.conclusion ?? step.status {
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
                Text("Loading log\u{2026}")
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

        // Derive owner/repo from the job's HTML URL.
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
            let text = fetchStepLog(scope: scope, jobID: jobId, stepNumber: stepNumber)
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
    // Matches ESC followed by the standard CSI sequences used in CI logs.
    let pattern = "\u{1b}(\\[[0-9;]*[A-Za-z]|\\][^\u{07}]*\u{07}|[^\\[\\]])"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
}
