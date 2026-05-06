import AppKit
import SwiftUI

// MARK: - Layout contract
// Navigation level 3 (PopoverMainView → JobDetailView → StepLogView).
// Root: .frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.top)
// Log MUST be inside ScrollView. Header MUST be outside ScrollView.
// ❌ NEVER add .idealWidth, .frame(height:), .fixedSize(), or resize here.

/// Shows the raw log text for a single `JobStep`.
///
/// Placed by `AppDelegate.navigate()` (rootView swap). Fits the fixed popover frame;
/// `ScrollView` absorbs overflow. Fetches log on `onAppear` via a background thread.
struct StepLogView: View {
    /// The job that owns this step.
    let job: ActiveJob
    /// The step whose log will be displayed.
    let step: JobStep
    /// Called when the user taps the back button.
    let onBack: () -> Void

    /// `nil` = not yet fetched; `""` = fetch returned empty; non-empty = log text.
    @State private var logText: String?
    /// True while the background fetch is in-flight.
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header — always visible, OUTSIDE ScrollView
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Steps").font(.caption)
                    }
                    .foregroundColor(.secondary)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                Spacer()
                LogCopyButton(
                    fetch: { completion in
                        let text = logText
                        DispatchQueue.global(qos: .userInitiated).async { completion(text) }
                    },
                    isDisabled: logText == nil || logText?.isEmpty == true
                )
                Text(step.elapsed)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)

            Text(step.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            Divider()

            // ── Log — INSIDE ScrollView
            ScrollView(.vertical, showsIndicators: true) {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small).padding(.vertical, 20)
                        Spacer()
                    }
                } else if let text = logText, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    Text("Log not available")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { loadLog() }
    }

    // MARK: - Log loading

    private func loadLog() {
        isLoading = true
        let jobID = job.id
        let stepNum = step.id
        let scope: String = {
            let parts = job.htmlUrl.components(separatedBy: "/")
            if parts.count >= 5 {
                let owner = parts[3]
                let repo = parts[4]
                if !owner.isEmpty && !repo.isEmpty { return "\(owner)/\(repo)" }
            }
            return ScopeStore.shared.scopes.first(where: { $0.contains("/") }) ?? ""
        }()
        DispatchQueue.global(qos: .userInitiated).async {
            let text = fetchStepLog(jobID: jobID, stepNumber: stepNum, scope: scope)
            DispatchQueue.main.async {
                logText = text ?? ""
                isLoading = false
            }
        }
    }
}
