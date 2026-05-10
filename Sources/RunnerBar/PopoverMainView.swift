import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57)
//
// RULE 1: Root VStack MUST use .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
//         AppDelegate reads hc.view.fittingSize in openPopover() to size the popover.
//         ❌ NEVER remove .frame(idealWidth: 420)
//         ❌ NEVER use .frame(width: 420)
//         ❌ NEVER remove maxWidth: .infinity
//         ❌ NEVER add .frame(height:) to root VStack
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: NEVER use .fixedSize() on any container.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).

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

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    /// Number of action groups currently visible in the paginated list.
    @State private var visibleCount: Int = 10

    /// Root layout: header → divider → optional rate-limit banner → runners → scrollable actions → quit.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeaderView(
                stats: systemStats.stats,
                isAuthenticated: isAuthenticated,
                onSelectSettings: onSelectSettings,
                onSignIn: signInWithGitHub
            )
            // Always render a separator after the header so the divider is visible
            // even when isRateLimited==false and all runners are offline.
            Divider()
            if store.isRateLimited { rateLimitBanner; Divider() }
            PopoverLocalRunnerRow(runners: store.runners)
                .onAppear { Task { await LocalRunnerStore.shared.refresh() } }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    actionsSection
                }
            }
            .frame(maxHeight: 400)
            Divider()
            quitButton
        }
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            systemStats.start()
        }
        .onDisappear { systemStats.stop() }
        // Reset pagination when the action list changes (e.g. after token refresh)
        // so the user never lands on an empty page.
        // ⚠️ Use the macOS 13-compatible single-value form — project targets macOS 13.0.
        // ❌ NEVER use { _, _ in } (two-argument closure) — that requires macOS 14+.
        .onChange(of: store.actions) { _ in visibleCount = 10 }
    }

    // MARK: - Rate limit banner

    /// Yellow warning strip shown when the GitHub API rate limit is reached.
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

    /// Paginated list of action groups with always-visible inline job rows for in-progress groups.
    /// Inline job rows are read-only (no tap action) per spec #324 Gap 2.
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

    /// Pagination button; renders nothing when all groups are already visible.
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

    // MARK: - Quit

    /// Quit RunnerBar button pinned to the popover bottom.
    private var quitButton: some View {
        Button(
            action: { NSApplication.shared.terminate(nil) },
            label: {
                Text("Quit RunnerBar")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
        )
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: - Helpers

    /// Opens the GitHub PAT setup docs in the default browser.
    /// NSAppleScript/Terminal-based device-flow was removed — the app never generates
    /// a user_code so the flow could never complete (ref #221).
    /// Auth.swift resolves the token via: `gh auth token` → `GH_TOKEN` → `GITHUB_TOKEN` (ref #246).
    private func signInWithGitHub() {
        let urlString = "https://docs.github.com/en/authentication/" +
            "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
