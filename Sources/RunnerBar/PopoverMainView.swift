import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57 #375 #376 #377)
//
// ARCHITECTURE 1: sizingOptions=.preferredContentSize (SwiftUI-driven dynamic height)
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
//   NSHostingController reads idealWidth as preferredContentSize.width = 480.
//   Width is always 480 → NSPopover never re-anchors horizontally → no side-jump.
//   ❌ NEVER remove .frame(idealWidth: 480)
//   ❌ NEVER use .frame(width: 480)
//   ❌ NEVER remove maxWidth: .infinity
//   ❌ NEVER add .frame(height:) or .frame(idealHeight:) to root VStack
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: NEVER use .fixedSize() on the root VStack.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).
//
// RULE 6: actionsSection MUST use .fixedSize(h:false, v:true) + .frame(maxHeight: cappedHeight).
//   ❌ NEVER wrap actionsSection in a ScrollView at this level.
//   ❌ NEVER remove .fixedSize(horizontal: false, vertical: true) from actionsSection.
//   ❌ NEVER remove .frame(maxHeight: cappedHeight) from actionsSection.
//   ❌ NEVER use a fixed constant — must adapt to screen size.
//
//   WHY NO ScrollView HERE:
//   ScrollView reports idealHeight = unbounded to SwiftUI. With sizingOptions=
//   .preferredContentSize, this makes the popover open at screen height regardless
//   of actual content. fixedSize(v:true) measures actual content height as
//   idealHeight. frame(maxHeight:) caps rendering. Popover height = min(content, cap).
//   If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//   UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//   is major major major.
//
// RULE 7: The 5 s timer calls LocalRunnerStore.shared.refresh() + store.reload().
//   BOTH are gated behind !popoverOpenState.isOpen.
//   LocalRunnerStore.shared.refresh() is @MainActor-isolated and MUST be called
//   via Task { @MainActor in ... } from the nonisolated Timer closure.
//   ❌ NEVER call store.reload() while popoverOpenState.isOpen == true.
//   ❌ NEVER call LocalRunnerStore.shared.refresh() while popoverOpenState.isOpen == true.
//   ❌ NEVER remove the !popoverOpenState.isOpen guard from the timer.
//   If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//   UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//   is major major major.
//
// RULE 8: idealWidth is 480. AppDelegate.fixedWidth is also 480.
//   ❌ NEVER change one without changing the other.
//
// RULE 9: systemStats MUST be paused while the popover is open.
//   SystemStatsViewModel fires every 2 s, mutating @StateObject → SwiftUI re-render
//   → intrinsicContentSize update. Belt-and-suspenders with sizingOptions=[].
//
//   ⚠️ CRITICAL — WHY @EnvironmentObject AND NOT A PLAIN Bool PROP:
//   AppDelegate constructs mainView() BEFORE the popover opens.
//   A plain `var isPopoverOpen: Bool` prop is captured as `false` at construction
//   time and NEVER updates inside the view (SwiftUI value-type props are copied,
//   not referenced). .onChange(of: isPopoverOpen) therefore NEVER fires.
//   PopoverOpenState is an ObservableObject injected as @EnvironmentObject by
//   wrapEnv(). It is mutated by AppDelegate immediately before show() and after
//   close(), so .onChange(of: popoverOpenState.isOpen) always sees the live value.
//   This is the SAME pattern used by InlineJobRowsView — which already works correctly.
//
//   ❌ NEVER re-add `var isPopoverOpen: Bool` prop to PopoverMainView.
//   ❌ NEVER read isPopoverOpen from a plain Bool prop here.
//   ❌ NEVER remove the .onChange(of: popoverOpenState.isOpen) systemStats gate.
//   ❌ NEVER pass isPopoverOpen: as a prop to PopoverMainView from AppDelegate.
//   If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//   UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//   is major major major.
struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void

    // ⚠️ RULE 9 — LIVE open-state signal from @EnvironmentObject.
    // Injected by AppDelegate via wrapEnv() / .environmentObject(popoverOpenState).
    // Mutated BEFORE show() and AFTER close() — always live.
    // ❌ NEVER replace with a plain Bool prop — it would be frozen at construction.
    // ❌ NEVER read from AppDelegate directly here.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    // is major major major.
    @EnvironmentObject private var popoverOpenState: PopoverOpenState

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    @State private var visibleCount: Int = 10
    @State private var runnerRefreshTimer: Timer?

    /// Screen-safe height cap for actionsSection.
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
                .onAppear {
                    Task {
                        await MainActor.run { LocalRunnerStore.shared.refresh() }
                    }
                }
            // ⚠️ RULE 6: actionsSection uses fixedSize+maxHeight — NO ScrollView wrapper.
            // .fixedSize(v:true) measures actual content height as idealHeight.
            // .frame(maxHeight:) caps rendering for screen safety.
            // idealHeight = min(actualContentHeight, cappedHeight) — truly dynamic.
            // 0 actions → ~40pt. 3 actions → ~3 rows. 20+ → capped at cappedHeight.
            // ❌ NEVER wrap this in ScrollView — ScrollView idealHeight = unbounded.
            // ❌ NEVER remove fixedSize — without it idealHeight is unconstrained.
            // ❌ NEVER replace maxHeight with height — height is a fixed size.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this
            // comment is removed is major major major.
            actionsSection
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: cappedHeight, alignment: .top)
        }
        // RULE 1: idealWidth:480 is LOAD-BEARING for preferredContentSize.width.
        // ❌ NEVER add .frame(height:) or .frame(idealHeight:) here.
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            if !popoverOpenState.isOpen {
                systemStats.start()
            }
            startRunnerRefreshTimer()
        }
        .onDisappear {
            systemStats.stop()
            stopRunnerRefreshTimer()
        }
        // ⚠️ RULE 9 — systemStats gate via LIVE @EnvironmentObject.
        // ❌ NEVER change to a plain Bool prop — see RULE 9 comment above.
        // ❌ NEVER remove this .onChange.
        // ⚠️ macOS 13-compatible single-value onChange — ❌ NEVER use { _, _ in }.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
        // is major major major.
        .onChange(of: popoverOpenState.isOpen) { open in
            if open {
                systemStats.stop()
            } else {
                systemStats.start()
            }
        }
        .onChange(of: store.actions) { _ in
            visibleCount = 10
        }
    }

    // MARK: - Runner refresh timer (RULE 7)
    private func startRunnerRefreshTimer() {
        stopRunnerRefreshTimer()
        runnerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            // ⚠️ RULE 7 — timer guard via LIVE @EnvironmentObject.
            // ❌ NEVER remove this guard (RULE 7).
            // ❌ LocalRunnerStore.shared.refresh() is @MainActor-isolated — MUST use
            //    Task { @MainActor in } from this nonisolated Timer closure.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            if !popoverOpenState.isOpen {
                Task { @MainActor in
                    LocalRunnerStore.shared.refresh()
                }
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
                        // ✅ InlineJobRowsView reads popoverOpenState via @EnvironmentObject
                        // ❌ NEVER pass isPopoverOpen: as a plain Bool prop
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
        let urlString = "https://docs.github.com/en/authentication/"
            + "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
