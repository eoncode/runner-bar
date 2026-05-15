import AppKit
import SwiftUI

// ╔════════════════════════════════════════════════════════════════════════════╗
// ║ ☹️  StepLogView — LAYOUT + SIZING CONTRACT ☹️                             ║
// ╠════════════════════════════════════════════════════════════════════════════╣
// ║ Navigation level 3 (PopoverMainView → JobDetailView → StepLogView).       ║
// ║                                                                            ║
// ║ LAYOUT RULES:                                                              ║
// ║ • Root: .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)      ║
// ║ • idealWidth: 480 hints SwiftUI’s initial natural width measurement.        ║
// ║   NSHostingController reads idealWidth as preferredContentSize.width        ║
// ║   on the first layout pass (NSPanel architecture, not NSPopover).           ║
// ║   The panel then resizes to content-driven width via KVO on                ║
// ║   preferredContentSize (see AppDelegate.sizeObservation).                  ║
// ║ • Log content MUST be inside the ScrollView.                               ║
// ║ • Header MUST be outside the ScrollView (always visible, not scrolled).   ║
// ║ ❌ NEVER use .frame(maxWidth: .infinity, maxHeight: .infinity) — the      ║
// ║    maxHeight: .infinity corrupts fittingSize.width when NSHostingCon-     ║
// ║    troller measures the view unconstrained (AppKit bug, see #375 #376)    ║
// ║ ❌ NEVER omit idealWidth: 480 from the root frame                         ║
// ║ ❌ NEVER add .frame(height:) here                                         ║
// ║ ❌ NEVER add .fixedSize() here                                            ║
// ║ ✔  ScrollView MUST have .frame(maxHeight: visibleFrame * 0.75) cap        ║
// ║    Without it, with sizingOptions=.preferredContentSize, SwiftUI           ║
// ║    reports the full log text height as preferredContentSize.height on     ║
// ║    navigate → panel grows off-screen. (ref #370)                          ║
// ║ ❌ NEVER remove the .frame(maxHeight:) from the ScrollView                ║
// ║                                                                            ║
// ║ If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT     ║
// ║ ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment   ║
// ║ is removed is major major major.                                           ║
// ╙────────────────────────────────────────────────────────────────────────────╜

/// Shows the raw log text for a single `JobStep`.
///
/// Issue #419 Phase 5: card-row grouping and monospaced metadata/log styling.
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
    /// Optional callback fired on the main thread once the async log fetch completes.
    ///
    /// ❌ NEVER call setFrameSize / contentSize directly from this closure.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    var onLogLoaded: (() -> Void)?
    /// `nil` = not yet fetched; `""` = fetch returned empty; non-empty = log text.
    @State private var logText: String?
    /// True while the background fetch is in-flight.
    @State private var isLoading = true

    // MARK: - Formatters (static to avoid re-allocation)
    private static let timeFmt: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dateFmt: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Top bar ──────────────────────────────────────────────────────────────────────────────────────────────
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
                if let urlString = job.htmlUrl, let url = URL(string: urlString) {
                    Button(
                        action: { NSWorkspace.shared.open(url) },
                        label: {
                            HStack(spacing: 3) {
                                Image(systemName: "safari").font(.caption)
                                Text("GitHub").font(.caption)
                            }
                            .foregroundColor(.secondary)
                            .fixedSize()
                        }
                    )
                    .buttonStyle(.plain)
                    .help("Open job on GitHub")
                }
                LogCopyButton(
                    fetch: { completion in
                        let text = logText
                        DispatchQueue.global(qos: .userInitiated).async { completion(text) }
                    },
                    isDisabled: logText == nil || logText?.isEmpty == true
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // ── Step name (large) ─────────────────────────────────────────────────────────────────────────────────────────────────────────
            Text(step.name)
                .font(RBFont.mono)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 5)

            // ── Meta rows ──────────────────────────────────────────────────────────────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "briefcase").font(.system(size: 10)).foregroundColor(.secondary)
                Text(job.name).font(RBFont.mono).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                Spacer()
                Text("step #\(step.id)")
                    .font(RBFont.monoSmall)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .pillBackground(color: .rbBlue, opacity: 0.10, borderOpacity: 0.20).fixedSize()
            }
            .padding(.horizontal, 12).padding(.bottom, 3)
            .cardRow()

            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 10)).foregroundColor(.secondary)
                Text(repoSlug).font(RBFont.mono).foregroundColor(.secondary).lineLimit(1).fixedSize()
                Spacer()
                Text("job #\(job.id)")
                    .font(RBFont.monoSmall)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .pillBackground(color: .rbBlue, opacity: 0.10, borderOpacity: 0.20).fixedSize()
            }
            .padding(.horizontal, 12).padding(.bottom, 3)
            .cardRow()

            HStack(spacing: 6) {
                Image(systemName: "clock").font(.system(size: 10)).foregroundColor(.secondary)
                Text(startLabel)
                    .font(RBFont.monoSmall).foregroundColor(.secondary).fixedSize()
                Text("→").font(.system(size: 10)).foregroundColor(.secondary)
                Text(endLabel)
                    .font(RBFont.monoSmall).foregroundColor(.secondary).fixedSize()
                Text("·").font(.system(size: 10)).foregroundColor(.secondary)
                Text(step.elapsed)
                    .font(RBFont.monoSmall).foregroundColor(.secondary).fixedSize()
                Text("·").font(RBFont.monoSmall).foregroundColor(.secondary)
                Text(dateLabel)
                    .font(RBFont.monoSmall).foregroundColor(.secondary).fixedSize()
                Spacer()
                Text(stepStatusLabel)
                    .font(.system(size: 10, weight: .medium)).foregroundColor(stepStatusColor).fixedSize()
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            .cardRow()

            Divider()

            // ── Log — INSIDE ScrollView ────────────────────────────────────────────────────────────────────────────────────────────────────────────
            // ⚠️ .frame(maxHeight:) cap is REQUIRED on this ScrollView (ref #370).
            // ❌ NEVER remove .frame(maxHeight:) from this ScrollView.
            ScrollView(.vertical, showsIndicators: true) {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small).padding(.vertical, 20)
                        Spacer()
                    }
                } else if let text = logText, !text.isEmpty {
                    Text(text)
                        .font(RBFont.mono)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .cardRow()
                } else {
                    Text("Log not available")
                        .font(.caption).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .cardRow()
                }
            }
            // ❌ NEVER remove this modifier.
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear {
            guard isLoading else { return }
            let job = self.job
            let step = self.step
            DispatchQueue.global(qos: .userInitiated).async {
                let text = LogFetcher.fetchLog(job: job, step: step)
                DispatchQueue.main.async {
                    self.logText = text
                    self.isLoading = false
                    self.onLogLoaded?()
                }
            }
        }
    }

    // MARK: - Helpers

    private var repoSlug: String {
        guard let url = job.htmlUrl else { return "" }
        let parts = url
            .replacingOccurrences(of: "https://github.com/", with: "")
            .components(separatedBy: "/")
        guard parts.count >= 2 else { return url }
        return parts[0] + "/" + parts[1]
    }

    private var startLabel: String {
        guard let d = step.startedAt else { return "—" }
        return Self.timeFmt.string(from: d)
    }

    private var endLabel: String {
        guard let d = step.completedAt else { return "now" }
        return Self.timeFmt.string(from: d)
    }

    private var dateLabel: String {
        guard let d = step.startedAt else { return "" }
        return Self.dateFmt.string(from: d)
    }

    private var stepStatusLabel: String {
        if let c = step.conclusion { return c.uppercased() }
        return step.status.uppercased()
    }

    private var stepStatusColor: Color {
        switch step.conclusion {
        case "success": return .rbSuccess
        case "failure": return .rbDanger
        default:
            return step.status == "in_progress" ? .rbBlue : .secondary
        }
    }
}
