import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57 #375 #376 #377)
//
// ARCHITECTURE 2: sizingOptions=[] (manual contentSize once before show)
// AppDelegate sets sizingOptions=[] — hosting controller NEVER auto-writes
// preferredContentSize to NSPopover. All sizing is owned by openPopover().
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
//   idealWidth: 480 gives fittingSize a stable width basis during measurement in
//   openPopover(). Width is always 480 → NSPopover never re-anchors horizontally.
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
//   WHY NO ScrollView HERE (Architecture 2):
//   ScrollView reports fittingSize.height = cappedHeight regardless of content.
//   openPopover() reads fittingSize before show() — a ScrollView makes the popover
//   open at cappedHeight even with 0 actions. fixedSize(v:true) measures ACTUAL
//   content height as fittingSize.height. frame(maxHeight:) caps rendering.
//   Popover height = min(actualContentHeight, cappedHeight) — truly dynamic.
//   - 0 actions → ~40pt. 3 actions → ~3 rows. 20+ → capped at cappedHeight.
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
//   SystemStatsViewModel fires every 2 s, mutating @StateObject → SwiftUI re-render.
//   Under Architecture 2 (sizingOptions=[]) this does NOT cause a jump directly,
//   but stopping stats while open is belt-and-suspenders safety.
//
//   ⚠️ CRITICAL — WHY @EnvironmentObject AND NOT A PLAIN Bool PROP:
//   AppDelegate constructs mainView() BEFORE the popover opens.
//   A plain `var isPopoverOpen: Bool` prop is captured as `false` at construction
//   time and NEVER updates inside the view (SwiftUI value-type props are copied,
//   not referenced). .onChange(of: isPopoverOpen) therefore NEVER fires.
//   PopoverOpenState is an ObservableObject injected as @EnvironmentObject by
//   wrapEnv(). It is mutated by AppDelegate immediately before show() and after
//   close(), so .onChange(of: popoverOpenState.isOpen) always sees the live value.
//
//   ❌ NEVER re-add `var isPopoverOpen: Bool` prop to PopoverMainView.
//   ❌ NEVER read isPopoverOpen from a plain Bool prop here.
//   ❌ NEVER remove the .onChange(of: popoverOpenState.isOpen) systemStats gate.
//   ❌ NEVER pass isPopoverOpen: as a prop to PopoverMainView from AppDelegate.
//   If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//   UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//   is major major major.
//
// RULE 10: loadMoreButton MUST be disabled while popoverOpenState.isOpen == true.
//   Tapping loadMoreButton increments visibleCount (@State mutation while shown).
//   Under Architecture 2 (sizingOptions=[]), SwiftUI re-renders PopoverMainView,
//   fixedSize(v:true) re-measures natural height, and if it differs from the fixed
//   frame set by openPopover(), AppKit resizes the window → re-anchor → side-jump.
//   Disabling the button prevents visibleCount mutation while the popover is open.
//   visibleCount ONLY increments after the popover is closed and reopened — at that
//   point openPopover() remeasures fittingSize and sets a correct new contentSize.
//   ❌ NEVER remove .disabled(popoverOpenState.isOpen) from loadMoreButton.
//   ❌ NEVER allow visibleCount to mutate while popoverOpenState.isOpen == true.
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
            // .fixedSize(v:true) measures actual content height for fittingSize in openPopover().
            // .frame(maxHeight:) caps rendering for screen safety.
            // ❌ NEVER wrap this in ScrollView — ScrollView fittingSize.height = cappedHeight always.
            // ❌ NEVER remove fixedSize — without it fittingSize.height is unconstrained/wrong.
            // ❌ NEVER replace maxHeight with height — height is a fixed size not a cap.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this
            // comment is removed is major major major.
            actionsSection
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: cappedHeight, alignment: .top)
        }
        // RULE 1: idealWidth:480 gives fittingSize a stable width basis.
        // ❌ NEVER add .frame(height:) or .frame(idealHeight:) here.
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            // ⚠️ RULE 9 — start stats when popover opens (onAppear fires while isOpen=true).
            // ❌ NEVER invert this guard: `if !isOpen` would mean stats NEVER start on open.
            // The .onChange below handles open→stop and close→start transitions.
            // onAppear is the initial start — it fires once when the view first appears,
            // which is always after AppDelegate sets popoverOpenState.isOpen = true.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
            // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
            // is major major major.
            if popoverOpenState.isOpen {
                systemStats.start()
            }
            startRunnerRefreshTimer()
        }
        .onDisappear {
            systemStats.stop()
            stopRunnerRefreshTimer()
        }
        // ⚠️ RULE 9 — systemStats gate via LIVE @EnvironmentObject.
        // open=true → stop stats (no @Published mutations while popover is shown).
        // open=false → start stats (popover closed, safe to poll again).
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
            // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this
            // comment is removed is major major major.
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

    // ⚠️ RULE 10: loadMoreButton is DISABLED while popoverOpenState.isOpen == true.
    // Mutating visibleCount while open causes SwiftUI re-render → fixedSize re-measures
    // → frame change → AppKit window resize → re-anchor → side-jump.
    // The button is only tappable after the popover is closed (isOpen=false).
    // On next open, openPopover() remeasures fittingSize with the new visibleCount.
    // ❌ NEVER remove .disabled(popoverOpenState.isOpen).
    // ❌ NEVER allow visibleCount to mutate while popoverOpenState.isOpen == true.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    // is major major major.
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
            // ⚠️ RULE 10 — MUST be disabled while open. See comment above.
            .disabled(popoverOpenState.isOpen)
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
