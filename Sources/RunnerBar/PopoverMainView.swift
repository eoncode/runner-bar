import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57)
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
//         NSHostingController reads idealWidth as preferredContentSize.width = 480.
//         ❌ NEVER remove .frame(idealWidth: 480)
//         ❌ NEVER use .frame(width: 480)
//         ❌ NEVER remove maxWidth: .infinity
//         ❌ NEVER add .frame(height:) to root VStack
//         ❌ NEVER add .frame(maxHeight:) to root VStack or to the ScrollView.
//           NSPopover positions itself to stay on-screen automatically via AppKit.
//           A maxHeight cap produces empty space when content is shorter than cap,
//           and clips content when cap is smaller than content. Both are wrong.
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: NEVER use .fixedSize() on any container.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).
//
// RULE 7 (#19): runnerRefreshTimer fires every 5 s on the main thread.
//         store.reload() is ONLY called when !popoverIsOpen.
//         ❌ NEVER call store.reload() while popoverIsOpen == true.
//         ❌ Calling store.reload() while the popover is shown triggers a SwiftUI
//            layout pass → preferredContentSize update → NSPopover re-anchor → side-jump.
//         ❌ NEVER remove this timer or the runner rows will show stale CPU/MEM metrics.
//
// RULE 8 (#22): idealWidth is 480 (was 420). AppDelegate.idealWidth is also 480.
//         ❌ NEVER change one without changing the other.
//
// RULE 9 (#377): SystemStatsViewModel MUST be stopped while the popover is open.
//         systemStats fires every 2 s unconditionally. Its @Published var stats
//         update mutates @StateObject systemStats inside PopoverMainView, triggering
//         a SwiftUI layout pass. With sizingOptions = .preferredContentSize, that
//         layout pass propagates a new preferredContentSize to NSPopover, which
//         re-anchors the window — side-jump every 2 s.
//         ❌ NEVER remove the systemStats.stop()/start() calls in onChange(isPopoverOpen).
//         ❌ NEVER call systemStats.start() while popoverIsOpen == true.
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
    /// Set by AppDelegate. When true, store.reload() and systemStats are suppressed
    /// to prevent SwiftUI layout passes while the popover is shown (RULE 7, RULE 9).
    /// ❌ NEVER remove this property.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    var isPopoverOpen: Bool = false

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    @State private var visibleCount: Int = 10
    @State private var runnerRefreshTimer: Timer?

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
            // ⚠️ NO .frame(maxHeight:) or .frame(height:) on this ScrollView.
            // NSPopover positions itself to stay on screen automatically via AppKit.
            // ❌ NEVER add .frame(maxHeight:) here — causes empty space / clipping.
            // ❌ NEVER add .frame(height:) here — fixed height regression.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    actionsSection
                }
            }
        }
        // RULE 1: idealWidth:480 pins preferredContentSize.width = 480 always.
        // ❌ NEVER add maxHeight here. ❌ NEVER change idealWidth.
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            systemStats.start()
            startRunnerRefreshTimer()
        }
        .onDisappear {
            systemStats.stop()
            stopRunnerRefreshTimer()
        }
        // RULE 9: Stop systemStats while open. Restart on close.
        // ❌ NEVER remove this onChange block.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
        // is major major major.
        .onChange(of: isPopoverOpen) { open in
            if open { systemStats.stop() } else { systemStats.start() }
        }
        // ⚠️ macOS 13-compatible single-value onChange
        .onChange(of: store.actions) { _ in visibleCount = 10 }
    }

    // MARK: - Runner refresh timer (#19)

    private func startRunnerRefreshTimer() {
        stopRunnerRefreshTimer()
        runnerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            LocalRunnerStore.shared.refresh()
            // RULE 7: ❌ NEVER call store.reload() while isPopoverOpen == true.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE.
            if !isPopoverOpen { store.reload() }
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
