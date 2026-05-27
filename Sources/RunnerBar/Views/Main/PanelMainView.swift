// PanelMainView.swift
// RunnerBar
import RunnerBarCore
import SwiftUI
// REGRESSION GUARD — DO NOT REMOVE - see regression history (ref #52 #54 #57 #375 #376 #377)
//
// ARCHITECTURE: NSPanel + sizingOptions=.preferredContentSize
// Dynamic height is achieved via KVO on NSHostingController.preferredContentSize.
// AppDelegate observes it and calls NSPanel.setFrame() — zero jump (no anchor).
// SwiftUI views report their natural ideal size. No height caps needed here.
//
// RULE 1: Root VStack uses .frame(minWidth: 280, maxWidth: 900, alignment: .top)
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: RunnerViewModel.reload() uses withAnimation(nil).
//
// RULE 5: actionsSection uses ViewThatFits so content drives the panel height
// naturally. For short lists, the plain VStack is used (no scroll, no cap).
// For tall lists that exceed screenScrollMaxHeight, it falls through to the
// capped ScrollView so content remains reachable via scrolling.
// screenScrollMaxHeight = NSScreen.main.visibleFrame.height * 0.80.
// ❌ NEVER remove the ScrollView fallback from actionsSection.
// ❌ NEVER use a GeometryReader or preference key for this cap — it freezes
// at the initial layout height and prevents scrolling to expanded content.
// ❌ NEVER add .frame(maxHeight:) to the root VStack instead.
// ❌ NEVER replace ViewThatFits with a bare ScrollView + .frame(maxHeight:) —
// that pins preferredContentSize to the cap even for single-row lists, causing
// the panel to always render at maximum height regardless of actual content.
//
// RULE 6: systemStats MUST run only while the panel is open — stop it when the panel closes.
// RULE 6b: systemStats must START when the panel opens so charts are live while the user views them.
//
// RULE 7: RunnerStore self-schedules via its own adaptive timer after each fetch().
// ❌ NEVER add a second repeating timer in PanelMainView that calls
// store.reload() — it doubles API calls and drains GitHub quota.
// LocalRunnerStore.refresh() (local-only, no API) may be called from onAppear.
//
// RULE 8: AppDelegate.initPanelWidth is 320.
// RULE 9: displayTick fires every 1 second ALWAYS (no open-state gate).
/// Root panel view rendered inside the NSPanel.
/// Owns the display-tick timer and system-stats lifecycle.
/// API polling is owned entirely by RunnerStore's adaptive self-scheduling timer.
struct PanelMainView: View {
    /// The store property.
    @ObservedObject var store: RunnerViewModel
    /// Called when user taps a step row in an inline job list. (#455)
    let onStepTap: (ActiveJob, JobStep) -> Void
    /// The onSelectSettings constant.
    let onSelectSettings: () -> Void
    /// The panelVisibilityState property.
    @EnvironmentObject private var panelVisibilityState: PanelVisibilityState
    /// The isAuthenticated property.
    @State private var isAuthenticated = (githubToken() != nil)
    /// The systemStats property.
    @StateObject private var systemStats = SystemStatsViewModel()
    /// The visibleCount property.
    @State private var visibleCount: Int = 10
    /// The displayTick property.
    @State private var displayTick: Int = 0
    /// The displayTickTimer property.
    @State private var displayTickTimer: Timer?
    /// Maximum height for the scrollable actions section when content is too tall to fit naturally.
    /// Used only as the ScrollView fallback inside ViewThatFits (RULE 5).
    private var screenScrollMaxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.80
    }

    /// The subset of locally-installed runners whose name matches a currently
    /// in-progress job's runnerName. This is the single source of truth for
    /// what to display in the Local Runners section.
    ///
    /// Derivation (#948):
    ///   - Collect runner names from store.jobs where status == .inProgress
    ///     and runnerName is non-nil.
    ///   - Filter store.localRunners to those whose runnerName is in that set.
    ///
    /// store.jobs and store.localRunners are both updated in the same
    /// AppDelegate didUpdate → reload() cycle — no timing drift.
    ///
    /// ❌ DO NOT filter on RunnerModel.isBusy — it is set by RunnerStatusEnricher
    /// on a separate background cycle and always lags, causing empty rows. (#948)
    private var activeLocalRunners: [RunnerModel] {
        let activeNames = Set(
            store.jobs
                .filter { $0.status == .inProgress }
                .compactMap { $0.runnerName }
        )
        return store.localRunners.filter { activeNames.contains($0.runnerName) }
    }

    /// Root body: stacks the header, optional rate-limit banner, local-runner section, and scrollable actions list.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeaderView(
                statsVM: systemStats,
                isAuthenticated: isAuthenticated,
                onSelectSettings: onSelectSettings,
                onSignIn: signInWithGitHub
            )
            .onAppear { systemStats.start() }
            Divider()
            if store.isRateLimited { rateLimitBanner; Divider() }
            if !activeLocalRunners.isEmpty {
                SectionHeaderLabel(title: "Local Runners")
                PanelLocalRunnerRow(runners: activeLocalRunners)
            }
            Color.clear.frame(width: 0, height: 0)
                .onAppear {
                    Task { await MainActor.run { LocalRunnerStore.shared.refresh() } }
                }
            actionsSectionScrollable
        }
        .frame(minWidth: 280, maxWidth: 900, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            if panelVisibilityState.isOpen { systemStats.start() }
            startDisplayTickTimer()
        }
        .onDisappear {
            systemStats.stop()
            stopDisplayTickTimer()
        }
        .onChange(of: panelVisibilityState.isOpen) { _, open in
            if open { systemStats.start() } else { systemStats.stop() }
        }
        .onChange(of: store.actions) { _, _ in visibleCount = 10 }
    }
    // MARK: - Scrollable actions section (RULE 5)
    /// Uses `ViewThatFits` so short content drives the panel to its natural height
    /// with no scroll indicator. Only when content exceeds `screenScrollMaxHeight`
    /// does it fall through to the capped `ScrollView`, keeping all content reachable.
    ///
    /// ❌ NEVER replace with a bare `ScrollView + .frame(maxHeight:)` —
    /// that always reports `maxHeight` as the ideal height, pinning the panel at
    /// maximum size even for a single-row list.
    private var actionsSectionScrollable: some View {
        ViewThatFits(in: .vertical) {
            // Short content: natural height, no scroll bar.
            actionsSectionContent
            // Tall content: capped ScrollView so everything is still reachable.
            ScrollView(.vertical, showsIndicators: true) {
                actionsSectionContent
            }
            .frame(maxHeight: screenScrollMaxHeight)
        }
    }
    /// Vertical stack of the Workflows section header, `ActionRowView` items, and the load-more button.
    private var actionsSectionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(title: "Workflows")
            if store.actions.isEmpty {
                Text("No recent workflows")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                let visible = Array(store.actions.prefix(visibleCount))
                ForEach(visible) { group in
                    ActionRowView(
                        group: group,
                        tick: displayTick,
                        onStepTap: onStepTap
                    )
                }
                loadMoreButton
            }
        }
        .padding(.vertical, 4)
    }
    /// Button that appends the next batch of up to 10 workflow rows; hidden when all rows are visible.
    @ViewBuilder private var loadMoreButton: some View {
        let nextBatch = min(10, store.actions.count - visibleCount)
        if nextBatch > 0 {
            Button(
                action: { visibleCount += nextBatch },
                label: {
                    Text("Load \(nextBatch) more workflows\u{2026}")
                        .font(.caption).foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
    // MARK: - Display tick timer (RULE 9 — ungated, 1s)
    /// Schedules a 1-second repeating timer that increments `displayTick`, driving elapsed-time labels.
    private func startDisplayTickTimer() {
        stopDisplayTickTimer()
        displayTickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                self.displayTick &+= 1
            }
        }
    }
    /// Invalidates and nils the display-tick timer.
    private func stopDisplayTickTimer() {
        displayTickTimer?.invalidate()
        displayTickTimer = nil
    }
    // MARK: - Rate limit banner (#778)
    /// Inline banner shown at the top of the panel when GitHub rate-limiting is active.
    /// Displays a live countdown to the rate-limit reset time, updated every second via `displayTick`.
    private var rateLimitBanner: some View {
        _ = displayTick // swiftlint:disable:this redundant_discardable_let
        let countdownLabel: String
        if let resetDate = store.rateLimitResetDate {
            let remaining = max(0, resetDate.timeIntervalSinceNow)
            if remaining < 1 {
                countdownLabel = "resuming\u{2026}"
            } else if remaining < 60 {
                countdownLabel = "resets in \(Int(remaining))s"
            } else {
                let mins = Int(remaining) / 60
                let secs = Int(remaining) % 60
                countdownLabel = String(format: "resets in %dm %02ds", mins, secs)
            }
        } else {
            countdownLabel = "pausing polls"
        }
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow).font(.caption)
            Text("GitHub rate limit reached — \(countdownLabel)")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
    // MARK: - Helpers
    /// Opens the GitHub personal-access-token documentation page in the default browser.
    private func signInWithGitHub() {
        let urlString = "\(GitHubConstants.base)/en/authentication/"
            + "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
