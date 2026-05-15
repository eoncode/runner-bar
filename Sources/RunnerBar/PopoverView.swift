import SwiftUI

// MARK: - PopoverOpenState

/// Observable object that tracks whether the popover panel is currently visible.
/// Injected into the SwiftUI environment via `AppDelegate.wrapEnv(_:)`.
final class PopoverOpenState: ObservableObject {
    /// `true` while the NSPanel is on screen.
    @Published var isOpen: Bool = false
}

// MARK: - PopoverMainView

/// Root SwiftUI view rendered inside the NSPanel.
/// Receives all navigation callbacks from AppDelegate and owns the
/// tab-bar / main-content layout.
struct PopoverMainView: View {
    /// Observable wrapper around RunnerStore used for SwiftUI invalidation.
    @ObservedObject var store: RunnerStoreObservable
    /// Called when the user taps a runner job row.
    var onSelectJob: (ActiveJob) -> Void
    /// Called when the user taps an action group row.
    var onSelectAction: (ActionGroup) -> Void
    /// Called when the user taps the settings button.
    var onSelectSettings: () -> Void
    /// Called when the user taps an inline job row inside an action group.
    var onSelectInlineJob: (ActiveJob, ActionGroup) -> Void

    @EnvironmentObject private var popoverState: PopoverOpenState
    @State private var selectedTab: Tab = .runners

    /// Top-level tab identifiers.
    enum Tab {
        /// Self-hosted runner list tab.
        case runners
        /// GitHub Actions workflow tab.
        case actions
    }

    /// Main body: tab bar + selected tab content.
    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            tabContent
        }
        .frame(minWidth: 300)
    }

    /// Segmented tab bar at the top of the popover.
    private var tabBar: some View {
        HStack {
            tabButton(title: "Runners", tab: .runners)
            tabButton(title: "Actions", tab: .actions)
            Spacer()
            settingsButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Content area switching between runner and action tabs.
    private var tabContent: some View {
        Group {
            switch selectedTab {
            case .runners:
                RunnerListView(
                    runners: store.runners,
                    onSelectJob: onSelectJob
                )
            case .actions:
                ActionListView(
                    actions: store.actions,
                    onSelectAction: onSelectAction,
                    onSelectInlineJob: onSelectInlineJob
                )
            }
        }
    }

    /// Individual tab selector button.
    private func tabButton(title: String, tab: Tab) -> some View {
        Button(action: { selectedTab = tab }) {
            Text(title)
                .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                .foregroundColor(selectedTab == tab ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    /// Gear icon button that triggers settings navigation.
    private var settingsButton: some View {
        Button(action: onSelectSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
    }
}
