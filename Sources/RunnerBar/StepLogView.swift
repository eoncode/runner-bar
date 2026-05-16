import AppKit
import SwiftUI

// MARK: - StepLogView

/// Full-screen log viewer for a single workflow step.
/// Streams log text from `LogFetcher` and renders it in a monospaced scroll view.
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

    /// Initiates log fetching via `LogFetcher` on a background thread.
    private func fetchLog() {
        isLoading = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LogFetcher.shared.fetchStepLog(
                group: group,
                job: job,
                stepIndex: stepIndex
            )
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
                let result = LogFetcher.shared.fetchStepLog(
                    group: self.group,
                    job: self.job,
                    stepIndex: self.stepIndex
                )
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

// MARK: - Collection+safe

extension Collection {
    /// Returns the element at `index` if it exists, otherwise `nil`.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
