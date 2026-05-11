import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57 #375 #376 #377)
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
//         NSHostingController reads idealWidth as preferredContentSize.width = 480.
//         Width is always 480 → NSPopover never re-anchors horizontally → no side-jump.
//         ❌ NEVER remove .frame(idealWidth: 480)
//         ❌ NEVER use .frame(width: 480)
//         ❌ NEVER remove maxWidth: .infinity
//         ❌ NEVER add .frame(height:) or .frame(maxHeight:) to root VStack
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: NEVER use .fixedSize() on the root VStack.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).
//
// RULE 6: actionsSection MUST be wrapped in a ScrollView with a .frame(maxHeight:) cap.
//
//         Architecture 1 (sizingOptions=.preferredContentSize): SwiftUI auto-reports
//         the view’s ideal height to NSPopover. Without a height cap, adding/removing
//         action groups changes idealHeight → NSPopover resizes/repositions → height jump.
//
//         The ScrollView cap is computed as NSScreen.main?.visibleFrame.height * 0.75
//         — same pattern as ActionDetailView, JobDetailView, StepLogView, SettingsView.
//
//         ❌ NEVER remove the ScrollView from actionsSection.
//         ❌ NEVER remove .frame(maxHeight:) from the ScrollView.
//         ❌ NEVER use a fixed constant — must adapt to screen size.
//         ❌ NEVER use an uncapped ScrollView — causes preferredContentSize.height spike.
//         If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//         UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//         is major major major.
//
// RULE 7: The 5 s timer calls LocalRunnerStore.shared.refresh() + store.reload().
//         BOTH are gated behind !isPopoverOpen.
//         LocalRunnerStore.shared.refresh() is @MainActor-isolated and MUST be called
//         via Task { @MainActor in ... } from the nonisolated Timer closure.
//         ❌ NEVER call store.reload() while isPopoverOpen == true.
//         ❌ NEVER call LocalRunnerStore.shared.refresh() while isPopoverOpen == true.
//         ❌ NEVER remove the !isPopoverOpen guard from the timer.
//         ❌ NEVER call LocalRunnerStore.shared.refresh() directly from the Timer closure
//            — it is @MainActor isolated and requires Task { @MainActor in }.
//         If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//         UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//         is major major major.
//
// RULE 8: idealWidth is 480. AppDelegate.fixedWidth is also 480.
//         ❌ NEVER change one without changing the other.
//
// RULE 9: systemStats MUST be paused while the popover is open.
//         SystemStatsViewModel fires every 2 s, mutating @StateObject → SwiftUI re-render
//         → intrinsicContentSize update. Belt-and-suspenders with sizingOptions=[].
//         ❌ NEVER remove the .onChange(of: isPopoverOpen) systemStats gate.
//         If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//         UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//         is major major major.
//
// RULE 10: Load-more button increments visibleCount and is the only way to expand
//          the actions list. No onContentChanged callback needed — Architecture 1
//          auto-reports new height via preferredContentSize after SwiftUI re-renders.
//          The ScrollView cap prevents the height from exceeding cappedHeight.
//          If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//          UNDER ANY CIRCUMSTANCE.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void
    /// Set by AppDelegate. Gates timer calls and systemStats (RULE 7, RULE 9).
    /// ❌ NEVER remove this property.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    var isPopoverOpen: Bool = false

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    @State private var visibleCount: Int = 10
    @State private var runnerRefreshTimer: Timer?

    /// Height cap for the actionsSection ScrollView.
    /// 75% of visible screen height — matches ActionDetailView, JobDetailView, StepLogView.
    /// ❌ NEVER increase above 0.85 — popover may overflow off-screen.
    /// ❌ NEVER use a fixed constant — must adapt to screen size.
    private var cappedHeight: CGFloat {
        NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeaderView(
                stats: systemStats.stats,
                isAuthenticated: isAuthenticated,
                onSelectSettings: onSelectSettings,
                onSignIn: signInWithGitHub
            )
            Divider()
            if store.isRateLimited { rateLimitBanner; Divider() }
            PopoverLocalRunnerRow(runners: store.runners)
                .onAppear { Task { await MainActor.run { LocalRunnerStore.shared.refresh() } } }
            // ⚠️ RULE 6: actionsSection MUST be inside a ScrollView with .frame(maxHeight: cappedHeight).
            // The cap prevents preferredContentSize.height from spiking when actions change.
            // ❌ NEVER remove the ScrollView.
            // ❌ NEVER remove .frame(maxHeight: cappedHeight).
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            ScrollView(.vertical, showsIndicators: true) {
                actionsSection
            }
            .frame(maxHeight: cappedHeight)
        }
        // RULE 1: idealWidth:480 is LOAD-BEARING for preferredContentSize.width.
        // ❌ NEVER add .frame(height:) or .frame(maxHeight:) here.
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            if !isPopoverOpen { systemStats.start() }
            startRunnerRefreshTimer()
        }
        .onDisappear {
            systemStats.stop()
            stopRunnerRefreshTimer()
        }
        // ⚠️ RULE 9: systemStats gate. ❌ NEVER remove.
        // ⚠️ macOS 13-compatible single-value onChange — ❌ NEVER use { _, _ in }.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
        // is major major major.
        .onChange(of: isPopoverOpen) { open in
            if open { systemStats.stop() } else { systemStats.start() }
        }
        .onChange(of: store.actions) { _ in visibleCount = 10 }
    }

    // MARK: - Runner refresh timer (RULE 7)

    private func startRunnerRefreshTimer() {
        stopRunnerRefreshTimer()
        runnerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            // ❌ NEVER remove this guard (RULE 7).
            // ❌ LocalRunnerStore.shared.refresh() is @MainActor-isolated — MUST use
            //   Task { @MainActor in } from this nonisolated Timer closure.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this
            // comment is removed is major major major.
            if !isPopoverOpen {
                Task { @MainActor in LocalRunnerStore.shared.refresh() }
                store.reload()
            }
        }
    }

    private func stopRunnerRefreshTimer() {
        runnerRefreshTimer?.invalidate()
        runnerRefreshTimer = nil
    }

    // MARK: - Rate limit banner

    private var rateLimitBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow).font(.caption)
            Text("GitHub rate limit reached — pausing polls")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    // MARK: - Actions section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.actions.isEmpty {
                Text("No recent actions")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                let visible = Array(store.actions.prefix(visibleCount))
                ForEach(visible) { group in
                    ActionRowView(group: group, onSelect: { onSelectAction(group) })
                    if group.groupStatus == .inProgress && !group.jobs.isEmpty {
                        // ✅ InlineJobRowsView reads isPopoverOpen via @EnvironmentObject PopoverOpenState
                        // ❌ NEVER pass isPopoverOpen: as a plain Bool prop — it was frozen at
                        //   construction time (always false). The environment object is live.
                        InlineJobRowsView(group: group)
                    }
                }
                loadMoreButton
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var loadMoreButton: some View {
        let nextBatch = min(10, store.actions.count - visibleCount)
        if nextBatch > 0 {
            // Architecture 1: no onContentChanged callback needed.
            // After visibleCount increments, SwiftUI re-renders and auto-reports
            // the new preferredContentSize to NSPopover. The ScrollView cap
            // (cappedHeight) prevents the height from exceeding screen bounds.
            Button(
                action: { visibleCount += nextBatch },
                label: {
                    Text("Load \(nextBatch) more actions\u{2026}")
                        .font(.caption).foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    // MARK: - Helpers

    private func signInWithGitHub() {
        let urlString = "https://docs.github.com/en/authentication/" +
            "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
