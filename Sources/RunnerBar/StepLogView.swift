import SwiftUI

// MARK: - Step Log View
//
// ============================================================
// ⚠️  WARNING — POPOVER SIZING CONTRACT — READ BEFORE EDITING
// ============================================================
// This view is a child inside JobStepsView's Group, which is
// itself a nav state inside PopoverView's root Group.
// PopoverView root Group has .frame(idealWidth: 340).
//
// RULE: child nav views must NEVER set .frame(width: N).
//   ✗ .frame(width: 340, height: 480)  ← overrides ideal width => left jump
//   ✓ .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
//
// See GitHub issues #53 and #54 before touching any of this.
// ============================================================

struct StepLogView: View {
    let job: ActiveJob
    let step: JobStep
    let scope: String
    let onBack: () -> Void

    @State private var lines: [String] = []
    @State private var isLoading = true
    @State private var truncated = false
    @State private var errorMessage: String? = nil

    private let maxLines = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header
            HStack(spacing: 6) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(step.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(job.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // ── Log content
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView().padding(.vertical, 16)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else if let err = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 24)
            } else if lines.isEmpty {
                Text("No log output available")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxHeight: .infinity)
            } else {
                if truncated {
                    Text("(showing last \(maxLines) lines)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.primary.opacity(0.85))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
        // ⚠️ maxWidth:.infinity — DO NOT use width:340 here.
        // width:340 overrides the root Group's idealWidth:340 and breaks
        // preferredContentSize.width => left jump. See contract above.
        .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
        .onAppear { loadLog() }
    }

    // MARK: - Data

    private func loadLog() {
        isLoading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let (logLines, wasTruncated) = fetchStepLog(
                jobID: job.id,
                stepNumber: step.id,
                scope: scope,
                maxLines: maxLines
            )
            DispatchQueue.main.async {
                // Detect Azure BlobNotFound or any XML error response
                if logLines.count == 1,
                   let first = logLines.first,
                   first.contains("BlobNotFound") || first.hasPrefix("<?xml") || first.contains("<Error>") {
                    errorMessage = "Log unavailable\nGitHub has expired this step's log."
                    lines = []
                } else {
                    lines = logLines
                    truncated = wasTruncated
                }
                isLoading = false
            }
        }
    }
}
