import AppKit
import SwiftUI

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  ☠️  StepLogView — LAYOUT + SIZING CONTRACT  ☠️                              ║
// ╠══════════════════════════════════════════════════════════════════════════════╣
// ║  Navigation level 3 (PopoverMainView → JobDetailView → StepLogView).        ║
// ║                                                                              ║
// ║  LAYOUT RULES (Architecture 1 — sizingOptions = .preferredContentSize):     ║
// ║    • Root VStack: .frame(maxWidth: .infinity, alignment: .top)               ║
// ║      NO maxHeight: .infinity on root — that defeats Architecture 1.         ║
// ║    • ScrollView: MUST have .frame(maxHeight: 75% of visible screen).        ║
// ║      Without the cap, ScrollView reports full log height as ideal height.   ║
// ║      preferredContentSize.height spikes → NSPopover re-anchors → side-jump. ║
// ║    • Log MUST be inside the ScrollView.                                     ║
// ║    • Header MUST be outside the ScrollView (always visible).                ║
// ║    ❌ NEVER add .idealWidth here                                             ║
// ║    ❌ NEVER add .frame(height:) to the root VStack                          ║
// ║    ❌ NEVER add .fixedSize() to the root VStack                             ║
// ║    ❌ NEVER add maxHeight: .infinity to the root VStack                     ║
// ║    ❌ NEVER remove .frame(maxHeight:) from the ScrollView — side-jump #370  ║
// ║                                                                              ║
// ║  NOTE: Previous versions used onLogLoaded / remeasurePopover (Architecture  ║
// ║  2 thinking). That approach is retired. Architecture 1 sizes via            ║
// ║  preferredContentSize automatically — no callbacks needed.                  ║
// ║                                                                              ║
// ║  If you are an agent or human, DO NOT REMOVE THIS COMMENT.                 ║
// ║  The regression we get when this comment is removed is major.              ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

/// Shows the raw log text for a single `JobStep`.
///
/// Height is capped at 75% of the visible screen height via .frame(maxHeight:)
/// on the ScrollView. This is required under Architecture 1 to prevent
/// preferredContentSize.height from spiking to the full log content height,
/// which would cause NSPopover to side-jump on navigation (#370).
///
/// ❌ NEVER remove .frame(maxHeight:) from the ScrollView.
/// ❌ NEVER add maxHeight: .infinity to the root VStack.
struct StepLogView: View {
    let job: ActiveJob
    let step: JobStep
    let onBack: () -> Void

    @State private var logText: String?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — OUTSIDE ScrollView, always visible.
            // ❌ NEVER move into the ScrollView.
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

            // ⚠️ .frame(maxHeight:) is REQUIRED — do NOT remove.
            // Without it, ScrollView reports full log height as ideal height,
            // causing preferredContentSize.height to spike → NSPopover side-jump (#370).
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
            // ⚠️ REQUIRED — caps preferredContentSize.height under Architecture 1.
            // Prevents NSPopover side-jump on navigation (#370).
            // ❌ NEVER remove this modifier.
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear { loadLog() }
    }

    private func loadLog() {
        isLoading = true
        let jobID = job.id
        let stepNum = step.id
        let scope: String = {
            let parts = job.htmlUrl?.components(separatedBy: "/") ?? []
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
