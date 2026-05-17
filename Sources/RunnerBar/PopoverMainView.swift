import SwiftUI

/// Root view for the main popover panel.
struct PopoverMainView: View {
    @EnvironmentObject private var callbacks: NavigationCallbacks

    var body: some View {
        PopoverMainViewSubviews(
            onSelectJob: callbacks.onSelectJob,
            onSelectAction: callbacks.onSelectAction,
            onSelectSettings: callbacks.onSelectSettings,
            onSelectInlineJob: callbacks.onSelectInlineJob
        )
    }
}

// MARK: - PopoverMainViewSubviews

/// Layout shell that wires store data into the popover scroll view.
///
/// ⚠️ SystemStatsViewModel is NOT injected by AppDelegate.wrapEnv() — it must
/// be owned here as a @StateObject. Do NOT change to @EnvironmentObject.
struct PopoverMainViewSubviews: View {
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void
    let onSelectInlineJob: ((ActiveJob, ActionGroup) -> Void)?

    @EnvironmentObject private var store: RunnerStoreObservable
    @EnvironmentObject private var popoverOpenState: PopoverOpenState

    @StateObject private var statsVM = SystemStatsViewModel()

    @State private var tick: Int = 0
    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// fix(#441 bug2): also true when store data is already flowing.
    private var isAuthenticated: Bool {
        !SettingsStore.shared.githubToken.isEmpty
            || !store.actions.isEmpty
            || !store.jobs.isEmpty
            || !store.runners.isEmpty
    }

    /// fix(#441 bug5): jobs already inlined under an ActionGroup must not
    /// appear again in the standalone JOBS section.
    private var standaloneJobs: [ActiveJob] {
        let actionJobIDs = Set(store.actions.flatMap { $0.jobs.map(\.id) })
        return store.jobs.filter { !actionJobIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeaderView(
                stats: statsVM.stats,
                cpuHistory: statsVM.cpuHistory,
                memHistory: statsVM.memHistory,
                // fix(#452): pass live diskHistory instead of hardcoded []
                diskHistory: statsVM.diskHistory,
                isAuthenticated: isAuthenticated,
                onSelectSettings: onSelectSettings,
                onSignIn: onSelectSettings
            )
            Divider()
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    PopoverLocalRunnerRow(runners: store.runners)
                    if !store.actions.isEmpty {
                        SectionHeaderLabel(title: "Actions")
                        ForEach(store.actions) { group in
                            ActionRowView(
                                group: group,
                                tick: tick,
                                onSelect: { onSelectAction(group) },
                                onSelectJob: onSelectInlineJob
                            )
                        }
                    }
                    if !standaloneJobs.isEmpty {
                        SectionHeaderLabel(title: "Jobs")
                        ForEach(standaloneJobs) { job in
                            Button(action: { onSelectJob(job) }) {
                                HStack(spacing: 8) {
                                    // fix(#452): status driven by actual job status not hardcoded .inProgress
                                    DonutStatusView(
                                        status: job.typedStatus,
                                        conclusion: job.conclusion,
                                        progress: job.progressFraction
                                    )
                                    Text(job.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .layoutPriority(1)
                                    Spacer()
                                    Text(job.elapsed)
                                        .font(DesignTokens.Fonts.mono)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, DesignTokens.Spacing.rowHPad)
                                .padding(.vertical, 5)
                                // fix(#452): card background matching runner rows and action rows
                                .background(
                                    RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                                        .fill(DesignTokens.Colors.rowBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                                                .strokeBorder(DesignTokens.Colors.rowBorder, lineWidth: 0.5)
                                        )
                                )
                                .padding(.horizontal, DesignTokens.Spacing.rowHPad)
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if store.actions.isEmpty && standaloneJobs.isEmpty {
                        emptyState
                    }
                }
            }
        }
        .onAppear { statsVM.start() }
        .onDisappear { statsVM.stop() }
        .onReceive(tickTimer) { _ in tick &+= 1 }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("No active jobs")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}
