import SwiftUI

/// Root view for the main popover panel.
///
/// Reads callbacks from the `NavigationCallbacks` environment object injected
/// by AppDelegate via `wrapEnv`, so no init parameters are needed.
struct PopoverMainView: View {
    @EnvironmentObject private var callbacks: NavigationCallbacks
    @EnvironmentObject private var store: RunnerStoreObservable
    @EnvironmentObject private var statsVM: SystemStatsViewModel
    @EnvironmentObject private var popoverOpenState: PopoverOpenState
    @EnvironmentObject private var localRunnerStore: LocalRunnerStore

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
/// Separated from `PopoverMainView` so `PopoverView` can also instantiate it
/// directly without re-injecting all environment objects.
struct PopoverMainViewSubviews: View {
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void
    let onSelectInlineJob: ((ActiveJob, ActionGroup) -> Void)?

    @EnvironmentObject private var store: RunnerStoreObservable
    @EnvironmentObject private var statsVM: SystemStatsViewModel
    @EnvironmentObject private var popoverOpenState: PopoverOpenState

    @State private var tick: Int = 0
    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeaderView(
                stats: statsVM.stats,
                cpuHistory: statsVM.cpuHistory,
                memHistory: statsVM.memHistory,
                diskHistory: statsVM.diskHistory,
                isAuthenticated: store.isAuthenticated,
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
                    if !store.jobs.isEmpty {
                        SectionHeaderLabel(title: "Jobs")
                        ForEach(store.jobs) { job in
                            Button(action: { onSelectJob(job) }) {
                                JobRowView(job: job, tick: tick)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if store.actions.isEmpty && store.jobs.isEmpty {
                        emptyState
                    }
                }
            }
        }
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
