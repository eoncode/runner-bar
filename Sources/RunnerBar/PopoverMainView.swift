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
/// Subviews live in PopoverMainViewSubviews.swift and PopoverProgressViews.swift
/// to satisfy SwiftLint file_length (<400) and type_body_length (<200) limits.
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
    @State private var visibleCount: Int = 10
    @State private var expandedGroupIDs: Set<String> = []
    /// Per-group inline-job display caps. Default 4; increments of 4 via "Load more jobs".
    @State private var inlineJobsLimit: [String: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeaderView(
                stats: systemStats.stats,
                isAuthenticated: isAuthenticated,
                onSelectSettings: onSelectSettings,
                onSignIn: signInWithGitHub
            )
            if store.isRateLimited { rateLimitBanner; Divider() }
            PopoverLocalRunnerRow(runners: store.runners)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { actionsSection }
            }
            Divider()
            quitButton
        }
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            systemStats.start()
        }
        .onDisappear { systemStats.stop() }
        .onChange(of: store.actions) { _, newActions in
            let liveIDs = Set(newActions.map(\.id))
            expandedGroupIDs = expandedGroupIDs.intersection(liveIDs)
            inlineJobsLimit = inlineJobsLimit.filter { liveIDs.contains($0.key) }
        }
    }

    // MARK: - Rate limit banner

    /// Yellow warning banner shown when GitHub rate-limit is hit.
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

    /// Unified scrollable actions list with inline job expansion and pagination.
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
                        isExpanded: expandedGroupIDs.contains(group.id),
                        onSelect: { onSelectAction(group) },
                        onToggleExpand: { toggleExpand(group.id) }
                    )
                    if expandedGroupIDs.contains(group.id) {
                        InlineJobRowsView(
                            group: group,
                            jobLimit: jobLimitBinding(for: group.id),
                            onSelectJob: onSelectJob
                        )
                    }
                }
                if store.actions.count > visibleCount { loadMoreButton }
            }
        }
        .padding(.vertical, 4)
    }

    /// Pagination button. Label and action both use the same `nextBatch` value.
    private var loadMoreButton: some View {
        let nextBatch = min(10, store.actions.count - visibleCount)
        return Button(
            action: { visibleCount = min(visibleCount + nextBatch, store.actions.count) },
            label: {
                Text("Load \(nextBatch) more actions…")
                    .font(.caption).foregroundColor(.secondary)
            }
        )
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: - Quit

    /// Quit RunnerBar button pinned to the bottom of the popover.
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

    /// Toggles expand/collapse state for an action group.
    private func toggleExpand(_ id: String) {
        if expandedGroupIDs.contains(id) {
            expandedGroupIDs.remove(id)
        } else {
            expandedGroupIDs.insert(id)
        }
    }

    /// Returns a `Binding<Int>` into `inlineJobsLimit` for a group ID, defaulting to 4.
    private func jobLimitBinding(for id: String) -> Binding<Int> {
        Binding(
            get: { inlineJobsLimit[id] ?? 4 },
            set: { inlineJobsLimit[id] = $0 }
        )
    }

    /// Opens the GitHub PAT setup docs in the default browser.
    private func signInWithGitHub() {
        let urlString = "https://docs.github.com/en/authentication/" +
            "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
