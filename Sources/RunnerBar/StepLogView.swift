import AppKit
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════════
// ⚠️ REGRESSION GUARD — READ BEFORE TOUCHING (ref #52 #54 #57)
// ═══════════════════════════════════════════════════════════════════════════════
//
// Navigation level 3 (main → JobDetailView → StepLogView).
// This view is placed by AppDelegate.navigate() — a rootView swap — while
// the popover is OPEN. The popover frame is fixed (sized from mainView at open
// time). This view must fit within that frame; ScrollView absorbs any overflow.
//
// ── FRAME CONTRACT ────────────────────────────────────────────────────────────
//   Same fixed frame as JobDetailView (mainView fittingSize, set at popover open).
//   navigate() does rootView swap ONLY — zero size changes — so this view must
//   always fit the pre-existing frame regardless of log length.
//
// ── LAYOUT RULES ──────────────────────────────────────────────────────────────
//   ✔ Root: .frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.top)
//       Fills the fixed frame, pins content to top.
//   ✔ Log text MUST be inside ScrollView — may be many hundreds of lines
//   ✔ Header (back button + step name) MUST be OUTSIDE ScrollView — always visible
//       Without this, scrolling down hides the back button.
//   ❌ NEVER add .idealWidth — only meaningful under preferredContentSize (FORBIDDEN)
//   ❌ NEVER add .frame(height:) — fights AppDelegate’s fixed frame
//   ❌ NEVER add .fixedSize() — collapses view, breaks layout
//   ❌ NEVER call navigate() directly — use the onBack callback
//   ❌ NEVER resize from inside this view — popover is open, any resize = left-jump
struct StepLogView: View {
    let job: ActiveJob
    let step: JobStep
    let onBack: () -> Void

    // logText states:
    //   nil  — never used (isLoading gate prevents nil from showing)
    //   ""   — fetch returned empty / unavailable (shows "Log not available")
    //   text — actual log content for this step
    @State private var logText: String? = nil

    // isLoading: true while the background fetch is in-flight.
    // Drives the ProgressView spinner. Set to false on fetch completion.
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header: always visible, OUTSIDE ScrollView
            //
            // Must stay outside the ScrollView so the back button remains
            // accessible regardless of log length.
            // Spacer() between back button and elapsed time is load-bearing:
            // without it both items collapse left and overlap.
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Steps").font(.caption)  // back label matches JobDetailView’s level name
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()  // ⚠️ load-bearing — do NOT remove
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

            // Step name — may wrap to 2 lines for very long names.
            // fixedSize(horizontal:false, vertical:true) allows vertical growth
            // while honouring the container’s horizontal constraint.
            Text(step.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            Divider()  // separator between header and log content

            // ── Log content: INSIDE ScrollView
            //
            // ⚠️ ScrollView is REQUIRED — logs can be hundreds of lines.
            // Without it, content would overflow the fixed frame and be clipped or centred.
            ScrollView(.vertical, showsIndicators: true) {
                if isLoading {
                    // Spinner shown while fetchStepLog runs on the background thread.
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small).padding(.vertical, 20)
                        Spacer()
                    }
                } else if let text = logText, !text.isEmpty {
                    // Log text: monospaced font, selectable, full width.
                    // textSelection(.enabled) allows the user to copy log lines.
                    // .frame(maxWidth:.infinity, alignment:.leading) ensures the text
                    // block stretches to the full scroll area width.
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    // Empty fallback: fetch succeeded but returned no lines for this step.
                    Text("Log not available")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
        }
        // Root frame contract: fill the fixed popover frame, pin to top.
        // ❌ NEVER add .idealWidth — has no effect (fittingSize read from mainView)
        // ❌ NEVER add .frame(height:) — fights AppDelegate’s frame
        // ❌ NEVER add .fixedSize() — collapses the view
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { loadLog() }
    }

    // MARK: — Log loading

    // loadLog() — called once from onAppear.
    // Derives the repo scope from job.htmlUrl (ground truth) then dispatches
    // fetchStepLog to a background thread to avoid blocking the main thread
    // (which would freeze the popover UI).
    private func loadLog() {
        isLoading = true
        let jobID   = job.id
        let stepNum = step.id  // 1-based, matches ##[group] section index in GitHub log

        // Derive owner/repo scope from job.htmlUrl.
        //
        // job.htmlUrl format: "https://github.com/{owner}/{repo}/actions/runs/{run}/jobs/{id}"
        // Splitting by "/" gives:
        //   parts[0] = "https:"
        //   parts[1] = ""
        //   parts[2] = "github.com"
        //   parts[3] = owner
        //   parts[4] = repo
        //   parts[5…] = "actions", "runs", run_id, "jobs", job_id
        //
        // We need parts[3] and parts[4].
        //
        // Fallback: if htmlUrl is nil or malformed, use the first repo-scoped
        // scope from ScopeStore (i.e. the first scope containing "/").
        // Org-scoped scopes (no "/") are NOT supported by the jobs/logs API.
        let scope: String = {
            if let url = job.htmlUrl {
                let parts = url.components(separatedBy: "/")
                if parts.count >= 5 {
                    let owner = parts[3]
                    let repo  = parts[4]
                    if !owner.isEmpty && !repo.isEmpty {
                        return "\(owner)/\(repo)"
                    }
                }
            }
            // Fallback: first repo-scoped scope in user’s configured scopes
            return ScopeStore.shared.scopes.first(where: { $0.contains("/") }) ?? ""
        }()

        // Fetch on a background thread.
        // fetchStepLog calls the gh CLI which is a synchronous blocking process;
        // it MUST NOT run on the main thread or it will freeze the UI.
        // Results are delivered back to the main thread for @State updates.
        DispatchQueue.global(qos: .userInitiated).async {
            let text = fetchStepLog(jobID: jobID, stepNumber: stepNum, scope: scope)
            DispatchQueue.main.async {
                logText   = text ?? ""  // empty string → "Log not available" shown
                isLoading = false
            }
        }
    }
}
