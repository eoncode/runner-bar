import AppKit
import SwiftUI

// ⚠️ REGRESSION GUARD — Architecture 1 (ref #49 #51 #52 #53 #54 #57 #321 #370 #375 #376 #377)
//
// sizingOptions = .preferredContentSize + idealWidth:420 on root drives ALL sizing.
// Root frame MUST be fixed width AND fixed height — never maxHeight:.infinity.
//
// WHY maxHeight:.infinity CAUSES SIDE JUMP:
//   .infinity propagates the full uncapped ScrollView content height as
//   preferredContentSize.height on every state change (isLoading toggle, logText update).
//   NSPopover sees a changed contentSize → re-anchors → side jump on log load.
//
// FIX: fixed frame 420×480 on root. preferredContentSize = 420×480 always.
//   ScrollView clips and scrolls content internally. No jump possible.
//
// ❌ NEVER use .fixedSize inside a ScrollView here.
// ❌ NEVER remove idealWidth:420.
// ❌ NEVER revert maxHeight to .infinity — re-introduces the jump.

struct StepLogView: View {
    let job: ActiveJob
    let step: JobStep
    let onBack: () -> Void

    @State private var logText: String?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header: OUTSIDE ScrollView
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

            // ── Log content: INSIDE ScrollView
            // ⚠️ NO .fixedSize inside this ScrollView.
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
        // ⚠️ FIXED frame — NOT maxHeight:.infinity.
        // preferredContentSize = 420×480 always → NSPopover never re-anchors.
        // ❌ NEVER revert to maxHeight:.infinity.
        .frame(minWidth: 420, idealWidth: 420, maxWidth: 420,
               minHeight: 480, idealHeight: 480, maxHeight: 480)
        .onAppear { loadLog() }
    }

    private func loadLog() {
        isLoading = true
        let jobID = job.id
        let stepNum = step.id
        let scope: String = {
            let parts = job.htmlUrl?.components(separatedBy: "/") ?? []
            if parts.count >= 5 {
                let owner = parts[3]; let repo = parts[4]
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
