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
// RULE 4: NEVER use .fixedSize() on the root VStack or any scroll container.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).
//
// RULE 6: actionsSection MUST use .fixedSize(horizontal: false, vertical: true)
//         + .frame(maxHeight: maxScrollHeight, alignment: .top).
//
//         ❌ NEVER wrap actionsSection in a ScrollView.
//         WHY: ScrollView reports INFINITE fittingSize.height regardless of any
//         .frame(maxHeight:) cap applied to it. AppDelegate.openPopover() calls
//         CATransaction.flush() then reads hc.view.fittingSize.height to size the
//         popover BEFORE show(). With a ScrollView present, fittingSize.height equals
//         the full screen height (~900 pt) even with 2 rows, so the popover opens
//         massively oversized on every click.
//
//         .fixedSize(horizontal: false, vertical: true) tells SwiftUI to measure the
//         view at its natural (ideal) height. Combined with .frame(maxHeight:), the
//         layout height is capped but fittingSize.height correctly reflects the smaller
//         of natural-content-height and maxScrollHeight.
//
//         The pagination loadMoreButton limits visible rows to 10 at a time so the
//         natural content height stays bounded without needing a ScrollView for overflow.
//
//         ❌ NEVER remove .fixedSize — fittingSize will return 0 or screenHeight.
//         ❌ NEVER remove .frame(maxHeight: maxScrollHeight) — height explosion with
//            30+ cached action groups.
//         ❌ NEVER use a fixed constant for maxScrollHeight — must adapt to screen size.
//         If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//         UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//         is major major major.
//
// RULE 7: The 5 s timer calls LocalRunnerStore.shared.refresh() + store.reload().
//         BOTH are gated behind !isPopoverOpen.
//
//         LocalRunnerStore.shared.refresh() updates CPU/MEM metrics for local runners.
//         It can indirectly trigger a SwiftUI layout pass through PopoverLocalRunnerRow
//         which observes LocalRunnerStore. With sizingOptions=[], this does NOT propagate
//         to NSPopover — BUT as a belt-and-suspenders safety measure, BOTH calls are
//         gated behind !isPopoverOpen.
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
// RULE 8: idealWidth is 480. AppDelegate.idealWidth is also 480.
//         ❌ NEVER change one without changing the other or fittingSize height
//         will be computed at the wrong width, wrapping text and mis-sizing the popover.
//
// RULE 9: systemStats MUST be paused while the popover is open.
//         SystemStatsViewModel fires a 2-second timer that publishes @Published var stats
//         via DispatchQueue.main.async. Even with sizingOptions=[], this mutates @StateObject
//         → SwiftUI re-render → NSHostingController.view updates intrinsicContentSize →
//         NSPopover re-reads the content view frame and RE-ANCHORS → side-jump every 2s.
//         sizingOptions=[] prevents preferredContentSize propagation but does NOT prevent
//         NSPopover from observing its contentViewController.view's intrinsicContentSize
//         directly via AppKit's window resize machinery.
//
//         Fix: .onChange(of: isPopoverOpen) gates systemStats.start()/stop().
//         When isPopoverOpen becomes true → systemStats.stop().
//         When isPopoverOpen becomes false → systemStats.start().
//         The header shows last-known stats while open (stale by at most 2s — imperceptible).
//
//         ❌ NEVER remove the .onChange(of: isPopoverOpen) systemStats gate.
//         ❌ NEVER call systemStats.start() while isPopoverOpen == true.
//         If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//         UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//         is major major major.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void
    /// Set by AppDelegate. When true, store.reload() and
    /// LocalRunnerStore.shared.refresh() are suppressed in the timer,
    /// AND systemStats is paused (RULE 9).
    /// ❌ NEVER remove this property — it is the guard that prevents layout passes
    /// while the popover is shown. See RULE 7 and RULE 9 above.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    var isPopoverOpen: Bool = false

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    /// Number of action groups currently visible in the paginated list.
    @State private var visibleCount: Int = 10
    /// Timer that refreshes runner metrics (CPU/MEM) every 5 s.
    /// Kept as @State so it is tied to this view instance, not a global.
    /// ❌ NEVER remove — without this, runner rows show stale CPU/MEM values.
    @State private var runnerRefreshTimer: Timer?

    /// Maximum height for the actions list.
    /// Derived from the visible screen area so the popover never overflows off-screen.
    /// The 120 pt offset accounts for header + divider + runner rows + comfortable gap.
    /// ❌ NEVER replace with a fixed constant — must adapt to screen height.
    private var maxScrollHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 700) - 120
    }

    /// Root layout: header → divider → optional rate-limit banner → runners → actions list.
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
            // ⚠️ RULE 6: fixedSize + maxHeight cap is LOAD-BEARING — see regression guard above.
            // ❌ NEVER wrap in ScrollView — ScrollView reports infinite fittingSize.height.
            // ❌ NEVER remove .fixedSize — fittingSize returns 0 or screenHeight without it.
            // ❌ NEVER remove .frame(maxHeight:) — height explosion with many action groups.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            actionsSection
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: maxScrollHeight, alignment: .top)
        }
        // RULE 1: idealWidth:480 pins fittingSize.width = 480 always.
        // ❌ NEVER add maxHeight here. ❌ NEVER change idealWidth.
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            // Start systemStats only when popover is not open.
            // isPopoverOpen is always false on first appear — this is always safe.
            // RULE 9: systemStats must not run while popover is open.
            if !isPopoverOpen { systemStats.start() }
            startRunnerRefreshTimer()
        }
        .onDisappear {
            systemStats.stop()
            stopRunnerRefreshTimer()
        }
        // ⚠️ RULE 9: Gate systemStats on isPopoverOpen.
        // When popover opens → systemStats.stop() — no @Published mutations while shown.
        // When popover closes → systemStats.start() — header stats resume updating.
        // ❌ NEVER remove this .onChange block.
        // ❌ NEVER move systemStats.start() outside the else branch (must never start while open).
        // ⚠️ macOS 13-compatible single-value onChange — ❌ NEVER use { _, _ in } (macOS 14+ only).
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
        // is major major major.
        .onChange(of: isPopoverOpen) { open in
            if open {
                systemStats.stop()   // ✅ pause: no @Published mutation → no intrinsicContentSize change → no re-anchor
            } else {
                systemStats.start()  // ✅ resume: header stats live again when popover is closed
            }
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
            //   - store.reload() → layout pass → intrinsicContentSize change.
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
                    ActionRowView(group: group, onSelect: { onSelectAction(group) })
                    if group.groupStatus == .inProgress && !group.jobs.isEmpty {
                        InlineJobRowsView(group: group, isPopoverOpen: isPopoverOpen)
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
