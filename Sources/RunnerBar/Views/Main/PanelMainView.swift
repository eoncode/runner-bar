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
// RULE 5: actionsSection is wrapped in a ScrollView capped at screenScrollMaxHeight.
// screenScrollMaxHeight = NSScreen.main.visibleFrame.height * 0.80.
// This mirrors AppDelegate's 85% panel ceiling minus headroom for the header
// and runner rows above the list. The ScrollView is transparent for short lists
// (content fits, no scroll indicator) and activates only when expanded rows
// would push content off screen.
// ❌ NEVER remove the ScrollView from actionsSection.
// ❌ NEVER use a GeometryReader or preference key for this cap — it freezes
// at the initial layout height and prevents scrolling to expanded content.
// ❌ NEVER add .frame(maxHeight:) to the root VStack instead.
//
// RULE 6: systemStats MUST be stopped while the panel is open.
// RULE 6b: systemStats must RESTART when the main view becomes visible again.
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
    /// The screenScrollMaxHeight property.
    private var screenScrollMaxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.80
    }
    /// True only when at least one local runner is actively busy AND there is
    /// at least one in-progress workflow. Gates both the section header and
    /// PanelLocalRunnerRow so the section never appears without an active run.
    private var hasBusyLocalRunners: Bool {
        store.localRunners.contains { $0.isBusy }
            && store.actions.contains { $0.groupStatus == .inProgress }
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
            if hasBusyLocalRunners {
                SectionHeaderLabel(title: "Local Runners")
                PanelLocalRunnerRow(runners: store.localRunners)
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
            if !panelVisibilityState.isOpen { systemStats.start() }
            startDisplayTickTimer()
        }
        .onDisappear {
            systemStats.stop()
            stopDisplayTickTimer()
        }
        .onChange(of: panelVisibilityState.isOpen) { open in
            if open { systemStats.stop() } else { systemStats.start() }
        }
        .onChange(of: store.actions) { _ in visibleCount = 10 }
    }
    // MARK: - Scrollable actions section (RULE 5)
    /// Wraps `actionsSectionContent` in a `ScrollView` capped at `screenScrollMaxHeight`.
    private var actionsSectionScrollable: some View {
        ScrollView(.vertical, showsIndicators: true) {
            actionsSectionContent
        }
        .frame(maxHeight: screenScrollMaxHeight)
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
                    Text("Load \(nextBatch) more workflows…")
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
            self.displayTick &+= 1
        }
    }
    /// Invalidates and nils the display-tick timer.
    private func stopDisplayTickTimer() {
        displayTickTimer?.invalidate()
        displayTickTimer = nil
    }
    // MARK: - Rate limit banner
    /// Warning strip shown at the top of the actions list when GitHub's rate limit has been hit.
    private var rateLimitBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow).font(.caption)
            Text("GitHub rate limit reached — pausing polls")
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
