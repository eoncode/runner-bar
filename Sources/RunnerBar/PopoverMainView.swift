import SwiftUI

// ⚠️ REGRESSION GUARD — frame + layout rules (ref #52 #54 #57 #375 #376 #377)
// See also: status-bar-app-position-warning.md — Architecture 1 spec.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
//
// ARCHITECTURE IN USE: Architecture 1 — Fully Dynamic Height (SwiftUI-driven)
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 480)
//         ❌ NEVER remove .frame(idealWidth: 480)
//         ❌ NEVER use .frame(width: 480) — layout constraint ≠ ideal size
//         ❌ NEVER use .frame(maxWidth: .infinity) as root modifier
//         ❌ NEVER add .frame(height:) to root VStack — kills dynamic height
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: NEVER use .fixedSize() on the root VStack or any container that
//         wraps ALL content — only use it on the action list itself.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).
//
// RULE 6: Action list MUST use .fixedSize(horizontal: false, vertical: true)
//         + .frame(maxHeight: maxListHeight, alignment: .top)
//         ❌ NEVER wrap the action list in ScrollView — ScrollView reports
//            infinite preferred height to SwiftUI → breaks preferredContentSize
//            → popover grows to full screen or collapses.
//         ❌ NEVER remove .fixedSize(horizontal: false, vertical: true) —
//            without it, the list doesn’t report its natural height.
//         ❌ NEVER use .frame(height:) on the list — that is fixed, not dynamic.
//         The cap (maxListHeight) prevents the popover growing off-screen.
//         It is computed from NSScreen.main so it adapts to different screens.
//
// RULE 7: The 5 s timer calls store.reload().
//         In Architecture 1, store.reload() while popover is open is SAFE:
//         it triggers a SwiftUI layout pass → preferredContentSize.height updates
//         → dynamic height. Width stays 480. No jump.
//         LocalRunnerStore.shared.refresh() is @MainActor — call via Task {@MainActor}.
//
// RULE 8: idealWidth is 480 (was 420). AppDelegate.idealWidth is also 480.
//         ❌ NEVER change one without changing the other.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

/// Root popover view — unified scrollable Actions list per issue #294.
/// Subviews are in PopoverMainViewSubviews.swift to satisfy SwiftLint
/// file_length (<400) and type_body_length (<200) limits.
struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void
    /// Set by AppDelegate. Used only by InlineJobRowsView to gate cap expansion.
    /// In Architecture 1 this does NOT gate store.reload() or LocalRunnerStore.refresh()
    /// because height changes while shown are safe (only WIDTH must be stable).
    /// ❌ NEVER remove — InlineJobRowsView.isPopoverOpen depends on it.
    var isPopoverOpen: Bool = false

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    @State private var visibleCount: Int = 10
    /// Timer that refreshes runner metrics (CPU/MEM) every 5 s.
    /// ❌ NEVER remove — without this, runner rows show stale CPU/MEM values.
    @State private var runnerRefreshTimer: Timer?

    /// Maximum height cap for the action list.
    /// Derived from visible screen area minus header/divider/runner-row space.
    /// ❌ NEVER replace with a fixed constant — adapts to screen height.
    private var maxListHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 700) - 160
    }

    /// Root layout: header → divider → optional rate-limit banner → runners → action list.
    /// ⚠️ .frame(idealWidth: 480) on the VStack is ARCHITECTURE 1’s key constraint.
    /// It pins preferredContentSize.width = 480 regardless of content or nav state.
    /// Height is unconstrained here — the action list’s .frame(maxHeight:) provides the cap.
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
                .onAppear { Task { @MainActor in LocalRunnerStore.shared.refresh() } }
            // ⚠️ RULE 6: .fixedSize + .frame(maxHeight:) is LOAD-BEARING.
            // .fixedSize(horizontal:false, vertical:true) — lets list report natural height.
            // .frame(maxHeight: maxListHeight) — caps growth to avoid off-screen overflow.
            // ❌ NEVER replace with ScrollView — breaks preferredContentSize.
            // ❌ NEVER remove .fixedSize — list collapses to zero height.
            // ❌ NEVER use .frame(height:) — that is fixed, not dynamic.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
            // UNDER ANY CIRCUMSTANCE.
            actionsSection
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: maxListHeight, alignment: .top)
        }
        // ⚠️ RULE 1: idealWidth:480 is ARCHITECTURE 1’s anti-jump constraint.
        // ❌ NEVER remove or change to .frame(width:480) or .frame(maxWidth:.infinity).
        .frame(idealWidth: 480)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            systemStats.start()
            startRunnerRefreshTimer()
        }
        .onDisappear {
            systemStats.stop()
            stopRunnerRefreshTimer()
        }
        // ⚠️ macOS 13-compatible single-value onChange — ❌ NEVER use { _, _ in } (macOS 14+ only).
        .onChange(of: store.actions) { _ in visibleCount = 10 }
    }

    // MARK: - Runner refresh timer (RULE 7)

    private func startRunnerRefreshTimer() {
        stopRunnerRefreshTimer()
        runnerRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: 5,
            repeats: true
        ) { [self] _ in
            // In Architecture 1, store.reload() while popover is open is SAFE.
            // Height changes while shown don’t jump because only WIDTH must be stable.
            store.reload()
            // LocalRunnerStore.refresh() is @MainActor — must hop via Task.
            Task { @MainActor in
                LocalRunnerStore.shared.refresh()
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
                    Text("Load \(nextBatch) more actions…")
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
