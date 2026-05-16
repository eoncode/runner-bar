import AppKit
import SwiftUI

// MARK: - StepLogView

/// Full-screen log viewer for a single workflow step.
/// Fetches the full job log via `fetchJobLog` and extracts the relevant step section.
struct StepLogView: View {
    // MARK: - Input

    /// The workflow run this step belongs to.
    let group: ActionGroup
    /// The specific job containing the step.
    let job: ActiveJob
    /// The step index within the job to display logs for.
    let stepIndex: Int
    /// Callback fired when the user dismisses the view.
    var onDismiss: () -> Void = {}

    // MARK: - State

    @State private var logText: String = ""
    @State private var isLoading = true
    @State private var error: String?
    @State private var autoScroll = true

    // MARK: - Constants

    private let fontSize: CGFloat = 11

    // MARK: - Derived

    /// The step being displayed, resolved from `job.steps` by index.
    private var step: JobStep? { job.steps[safe: stepIndex] }

    /// Display title: step name if available, otherwise a fallback label.
    private var stepTitle: String {
        step?.name ?? "Step \(stepIndex + 1)"
    }

    // MARK: - Fetch

    /// Fetches the full job log and extracts the section for the target step.
    private func fetchLog() {
        isLoading = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = fetchStepLogText(group: group, job: job, stepIndex: stepIndex)
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let text): logText = text
                case .failure(let err):  self.error = err.localizedDescription
                }
            }
        }
    }

    // MARK: - Copy action

    /// Computed closure passed to `LogCopyButton`: re-fetches and returns the log text.
    private var copyFetch: (@escaping (String?) -> Void) -> Void {
        { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = fetchStepLogText(group: self.group, job: self.job, stepIndex: self.stepIndex)
                switch result {
                case .success(let text): completion(text)
                case .failure:           completion(nil)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Top bar
            HStack(spacing: 8) {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Back")

                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title)
                        .font(.system(size: 10)).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Text(stepTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                }

                Spacer()

                LogCopyButton(fetch: copyFetch, isDisabled: isLoading || logText.isEmpty)

                Toggle("", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .help("Auto-scroll to bottom")
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

            Divider()

            // ── Content
            if isLoading {
                VStack {
                    ProgressView("Loading log\u{2026}")
                        .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundColor(.secondary)
                    Text("Failed to load log")
                        .font(.headline)
                    Text(error)
                        .font(.caption).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { fetchLog() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(logText)
                            .font(.system(size: fontSize, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .id("logBottom")
                    }
                    .onChange(of: logText) { _ in
                        if autoScroll {
                            proxy.scrollTo("logBottom", anchor: .bottom)
                        }
                    }
                    .onAppear {
                        if autoScroll {
                            proxy.scrollTo("logBottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .onAppear { fetchLog() }
    }
}

// MARK: - Step log extraction

/// Fetches the full job log and extracts lines belonging to `stepIndex`.
/// GitHub job logs are plain text with section headers of the form:
///   ##[group]Step N: <name>
///   ##[endgroup]
/// We fall back to returning the entire log when headers are absent.
private enum StepLogError: LocalizedError {
    case noScope
    case fetchFailed
    var errorDescription: String? {
        switch self {
        case .noScope:     return "Cannot determine repository scope from job URL."
        case .fetchFailed: return "Failed to fetch log from GitHub."
        }
    }
}

func fetchStepLogText(
    group: ActionGroup,
    job: ActiveJob,
    stepIndex: Int
) -> Result<String, Error> {
    // Determine the repo scope: prefer the group's repo, fall back to the job URL.
    let scope: String
    if group.repo.contains("/") {
        scope = group.repo
    } else if let s = scopeFromHtmlUrl(job.htmlUrl), s.contains("/") {
        scope = s
    } else {
        return .failure(StepLogError.noScope)
    }

    guard let fullLog = fetchJobLog(jobID: job.id, scope: scope) else {
        return .failure(StepLogError.fetchFailed)
    }

    // Extract just the step's section if GitHub section markers are present.
    let extracted = extractStepSection(from: fullLog, stepIndex: stepIndex)
    return .success(extracted)
}

/// Extracts lines for a specific step (1-based in GitHub logs, 0-based `stepIndex` here).
/// GitHub log format uses `##[group]` / `##[endgroup]` to delimit steps.
/// If no markers are found, returns the whole log.
private func extractStepSection(from log: String, stepIndex: Int) -> String {
    let lines = log.components(separatedBy: "\n")
    var sections: [[String]] = []
    var current: [String]? = nil

    for line in lines {
        if line.hasPrefix("##[group]") {
            current = [line]
        } else if line.hasPrefix("##[endgroup]") {
            if var c = current {
                c.append(line)
                sections.append(c)
            }
            current = nil
        } else {
            current?.append(line)
        }
    }

    guard !sections.isEmpty else { return log }
    guard stepIndex < sections.count else { return sections.last?.joined(separator: "\n") ?? log }
    return sections[stepIndex].joined(separator: "\n")
}

// MARK: - Collection+safe

extension Collection {
    /// Returns the element at `index` if it exists, otherwise `nil`.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
