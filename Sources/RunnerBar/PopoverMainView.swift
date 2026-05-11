import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57 #375 #376 #377)
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
//         AppDelegate reads hc.view.fittingSize in openPopover() to size the popover.
//         ❌ NEVER remove .frame(idealWidth: 480)
//         ❌ NEVER use .frame(width: 480)
//         ❌ NEVER remove maxWidth: .infinity
//         ❌ NEVER add .frame(height:) to root VStack
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: NEVER use .fixedSize() on any container.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).
// RULE 6: ScrollView MUST have a .frame(maxHeight:) cap = visibleScreenHeight - 120.
//         Without this cap, fittingSize.height reports the full unbounded content
//         height (can be 1000pt+ with 30 cached groups), making the popover
//         grow off-screen. The cap is computed dynamically from NSScreen.main so
//         it adapts to different screen sizes and menu-bar positions.
//         ❌ NEVER remove this cap — causes height explosion with many action groups.
//         ❌ NEVER use a fixed constant — adapts to screen size.
//
// RULE 7: The 5 s timer calls LocalRunnerStore.shared.refresh() + store.reload().
//         BOTH are gated behind !isPopoverOpen.
//
//         LocalRunnerStore.shared.refresh() updates CPU/MEM metrics for local runners.
//         Even though it does not directly mutate the @ObservedObject `store`, it can
//         indirectly trigger a SwiftUI layout pass through PopoverLocalRunnerRow which
//         observes LocalRunnerStore. With sizingOptions=[], this does NOT propagate to
//         NSPopover — BUT as a belt-and-suspenders safety measure, and to avoid any
//         visible flicker or stale-data inconsistency while the popover is open, BOTH
//         calls are gated behind !isPopoverOpen.
//
//         store.reload() mutates @ObservedObject store → SwiftUI layout pass →
//         hosting controller updates intrinsicContentSize. With sizingOptions=[]
//         this does NOT reach NSPopover. But it is still wasteful while shown.
//
//         ❌ NEVER call store.reload() while isPopoverOpen == true.
//         ❌ NEVER call LocalRunnerStore.shared.refresh() while isPopoverOpen == true.
//         ❌ NEVER remove the !isPopoverOpen guard from the timer.
//         If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//         UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//         is major major major.
//
// RULE 8: idealWidth is 480 (was 420). AppDelegate.idealWidth is also 480.
//         ❌ NEVER change one without changing the other or fittingSize height
//         will be computed at the wrong width, wrapping text and mis-sizing the popover.
//
// RULE 9: SystemStatsViewModel MUST be stopped while the popover is open.
//         ❌ NEVER call systemStats.start() or leave systemStats running while shown.
//
//         ROOT CAUSE OF SIDE-JUMP (confirmed by Just10/MEMORY.md, #377, #375, #376):
//         SystemStatsViewModel.start() runs a repeating timer that updates @StateObject
//         systemStats. Every tick triggers:
//             SwiftUI layout pass
//             → hostingView.invalidateIntrinsicContentSize()
//             → NSPopover re-anchors → SIDE-JUMP
//
//         This occurs even with sizingOptions=[] because NSPopover has TWO paths that
//         trigger re-anchoring:
//           Path A: preferredContentSize auto-propagation — blocked by sizingOptions=[].
//           Path B: hostingView.invalidateIntrinsicContentSize() — NOT blocked by
//                   sizingOptions=[]. Any @StateObject or @ObservedObject change while
//                   the popover is shown triggers Path B and causes a side-jump.
//
//         The ONLY safe approach: no SwiftUI state must change while the popover is shown.
//         SystemStatsViewModel must be stopped on onAppear and started on onDisappear
//         (i.e., popover is closed). The header shows a snapshot of stats captured at
//         open time — it does NOT need live updates while the user is looking at it.
//
//         ❌ NEVER call systemStats.start() from onAppear.
//         ❌ NEVER leave systemStats running while the popover is shown.
//         ✅ Call systemStats.stop() in onAppear (popover shown = stop the timer).
//         ✅ Call systemStats.start() in onDisappear (popover closed = resume for
//            background snapshot before next open).
//         If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//         UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//         is major major major.
//
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

/// Root popover view — unified scrollable Actions list per issue #294.
/// Subviews are in PopoverMainViewSubviews.swift to satisfy SwiftLint
/// file_length (<400) and type_body_length (<200) limits.
struct PopoverMainView: View {
    /// The observable that bridges RunnerStore state into SwiftUI.
    @ObservedObject var store: RunnerStoreObservable
    /// Called when the user taps a job row to drill into job detail.
    let onSelectJob: (ActiveJob) -> Void
    /// Called when the user taps an action group row to drill into action detail.
    let onSelectAction: (ActionGroup) -> Void
    /// Called when the user taps the settings button.
    let onSelectSettings: () -> Void
    /// Set by AppDelegate. When true, BOTH store.reload() AND
    /// LocalRunnerStore.shared.refresh() are suppressed in the timer.
    /// ❌ NEVER remove this property — it is the guard that prevents layout passes
    /// while the popover is shown. See RULE 7 above.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    var isPopoverOpen: Bool = false

    @State private var isAuthenticated = (githubToken() != nil)
    // ⚠️ RULE 9: SystemStatsViewModel must NOT run while popover is open.
    // Stopped in onAppear (popover shown). Started in onDisappear (popover closed).
    // The header shows the snapshot captured during the previous background run.
    // ❌ NEVER call systemStats.start() from onAppear.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    // UNDER ANY CIRCUMSTANCE.
    @StateObject private var systemStats = SystemStatsViewModel()
    /// Number of action groups currently visible in the paginated list.
    @State private var visibleCount: Int = 10
    /// Timer that refreshes runner metrics (CPU/MEM) every 5 s.
    /// Kept as @State so it is tied to this view instance, not a global.
    /// ❌ NEVER remove — without this, runner rows show stale CPU/MEM values.
    @State private var runnerRefreshTimer: Timer?

    /// Maximum height for the scrollable actions list.
    /// Derived from the visible screen area so the popover never overflows off-screen.
    /// The 120 pt offset accounts for header + divider + runner rows + comfortable gap.
    /// ❌ NEVER replace with a fixed constant — must adapt to screen height.
    private var maxScrollHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 700) - 120
    }

    /// Root layout: header → divider → optional rate-limit banner → runners → scrollable actions.
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
                .onAppear { Task { LocalRunnerStore.shared.refresh() } }
            // ⚠️ RULE 6: maxHeight cap is LOAD-BEARING — see regression guard above.
            // ❌ NEVER remove .frame(maxHeight: maxScrollHeight)
            // ❌ NEVER change to .frame(height:) — clips content to a fixed value
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    actionsSection
                }
            }
            .frame(maxHeight: maxScrollHeight)
        }
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            // ✅ RULE 9: Stop systemStats immediately — popover is now shown.
            // Leaving it running causes @StateObject ticks →
            // invalidateIntrinsicContentSize() → NSPopover re-anchor → side-jump.
            // ❌ NEVER call systemStats.start() here.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            systemStats.stop()
            startRunnerRefreshTimer()
        }
        .onDisappear {
            // ✅ RULE 9: Resume systemStats after popover is closed so it captures
            // a fresh snapshot for the NEXT open.
            // ❌ NEVER move this start() call to onAppear.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            systemStats.start()
            stopRunnerRefreshTimer()
        }
        // ⚠️ macOS 13-compatible single-value onChange — ❌ NEVER use { _, _ in } (macOS 14+ only).
        .onChange(of: store.actions) { _ in visibleCount = 10 }
    }

    // MARK: - Runner refresh timer (RULE 7)

    private func startRunnerRefreshTimer() {
        stopRunnerRefreshTimer() // guard against double-start
        runnerRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: 5,
            repeats: true
        ) { _ in
            // ✅ BOTH calls gated behind !isPopoverOpen (RULE 7).
            // LocalRunnerStore.shared.refresh() — updates local runner CPU/MEM metrics.
            // store.reload()                   — mutates @ObservedObject store.
            // Neither must fire while the popover is open:
            //   - store.reload() → layout pass → intrinsicContentSize change (harmless
            //     with sizingOptions=[] but wastes CPU and can flicker).
            //   - LocalRunnerStore.shared.refresh() → can trigger layout pass through
            //     PopoverLocalRunnerRow which observes LocalRunnerStore.
            // Belt-and-suspenders: gate both. Zero cost when popover is closed.
            // ❌ NEVER remove this guard. See RULE 7 in the regression guard above.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this
            // comment is removed is major major major.
            if !isPopoverOpen {
                LocalRunnerStore.shared.refresh()
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
                    ActionRowView(
                        group: group,
                        onSelect: { onSelectAction(group) }
                    )
                    if group.groupStatus == .inProgress && !group.jobs.isEmpty {
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
