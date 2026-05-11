import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57 #375 #376 #377)
//
// ARCHITECTURE 3: sizingOptions=[] + GeometryReader/PreferenceKey dynamic height
//
// WHY THIS ARCHITECTURE:
// Architecture 1 (sizingOptions=.preferredContentSize): NSPopover re-anchors on
//   every SwiftUI state update while shown → side-jump every 2s.
// Architecture 2 (fittingSize before show()): RunnerStoreObservable.reload() is
//   async — data not yet available at measurement time → always ~300pt fallback.
// Architecture 3 (this file): render first, measure after, set once.
//   sizingOptions=[] prevents auto-propagation.
//   GeometryReader reports real rendered height via PreferenceKey.
//   AppDelegate receives height via onHeightReady callback, calls setContentSize ONCE.
//   heightReported flag ensures setContentSize is called exactly once per open.
//   animates=false → resize is invisible.
//
// RULE 1: Root VStack uses .frame(maxWidth: .infinity, alignment: .top)
//   Width is set externally via popover.contentSize.width = fixedWidth (480).
//   ❌ NEVER add .frame(height:) or .frame(maxHeight:) to root VStack.
//   ❌ NEVER add .fixedSize() to root VStack.
//   ❌ NEVER use idealWidth here — width is controlled by AppDelegate contentSize.
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: NEVER use .fixedSize() on the root VStack.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).
//
// RULE 6: actionsSection is wrapped in a ScrollView with .frame(maxHeight: cappedHeight).
//   This allows the content to be arbitrarily tall while capping visual render height.
//   The PreferenceKey measures the SCROLLVIEW height (capped), not content height.
//   So the popover height = header + runners + min(actions, cappedHeight).
//   ❌ NEVER remove the ScrollView cap.
//   ❌ NEVER measure content height inside the ScrollView for the PreferenceKey.
//   If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//   UNDER ANY CIRCUMSTANCE.
//
// RULE 7: Timer gates behind !popoverOpenState.isOpen (RULE 7 unchanged).
//   ❌ NEVER remove the guard. ❌ NEVER call reload() while open.
//   If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//   UNDER ANY CIRCUMSTANCE.
//
// RULE 8: fixedWidth = 480 in both AppDelegate and content view.
//   ❌ NEVER change one without the other.
//
// RULE 9: systemStats MUST stop while open. Reads popoverOpenState via @EnvironmentObject.
//   ❌ NEVER re-add `var isPopoverOpen: Bool` prop — frozen at construction time.
//   ❌ NEVER remove .onChange(of: popoverOpenState.isOpen) systemStats gate.
//   If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//   UNDER ANY CIRCUMSTANCE.
//
// RULE 10: PreferenceKey height callback fires ONCE per open (heightReported guard).
//   ❌ NEVER call onHeightReady more than once per open.
//   ❌ NEVER remove the `guard !popoverOpenState.heightReported` check.
//   If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//   UNDER ANY CIRCUMSTANCE.
struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void

    // ⚠️ RULE 9 — LIVE open-state via @EnvironmentObject.
    // ❌ NEVER replace with a plain Bool prop — frozen at construction time.
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    // UNDER ANY CIRCUMSTANCE.
    @EnvironmentObject private var popoverOpenState: PopoverOpenState

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    @State private var visibleCount: Int = 10
    @State private var runnerRefreshTimer: Timer?

    /// Height cap for the actionsSection ScrollView.
    /// 75% of visible screen height — prevents popover overflowing off-screen.
    /// ❌ NEVER use a fixed constant. ❌ NEVER increase above 0.85.
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
            // RULE 6: ScrollView caps render height; PreferenceKey measures this cap.
            ScrollView(.vertical, showsIndicators: true) {
                actionsSection
            }
            .frame(maxHeight: cappedHeight)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // ⚠️ RULE 10 — GeometryReader reports rendered height to AppDelegate.
        // .background() is used so the GeometryReader doesn't affect layout.
        // .onPreferenceChange fires after EVERY layout pass — heightReported
        // flag ensures setContentSize is called exactly ONCE per open.
        // ❌ NEVER remove this block.
        // ❌ NEVER move the GeometryReader inside actionsSection or the ScrollView.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
        // is major major major.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: PopoverHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(PopoverHeightKey.self) { height in
            // ⚠️ RULE 10: Only fire once per open (heightReported guard).
            // height > 10 guards against spurious zero-height layout passes.
            // ❌ NEVER remove the heightReported guard.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            guard height > 10, !popoverOpenState.heightReported else { return }
            popoverOpenState.heightReported = true
            popoverOpenState.onHeightReady?(height)
        }
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
        // ❌ NEVER change to plain Bool prop. ❌ NEVER remove this .onChange.
        // ⚠️ macOS 13-compatible single-value onChange — ❌ NEVER use { _, _ in }.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
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
            if !popoverOpenState.isOpen {
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
                        // ✅ Reads popoverOpenState via @EnvironmentObject — never a frozen prop.
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
