import SwiftUI

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57 #375 #376 #377)
//
// ARCHITECTURE 2: sizingOptions=[] (manual fittingSize measurement before show)
// AppDelegate.openPopover() is the ONLY place contentSize is written.
//
// VIEW RULES (Architecture 2):
//
// RULE 1: Root VStack has NO frame constraints other than maxWidth:.infinity.
//   AppDelegate reads fittingSize.height after a full layout pass (height=9999).
//   Any .frame(idealWidth:), .fixedSize(), or .frame(maxHeight:) on this view or
//   its children would corrupt that measurement.
//   ❌ NEVER add .frame(idealWidth:) — not read by sizingOptions=[]
//   ❌ NEVER add .fixedSize() to root or actionsSection — corrupts fittingSize
//   ❌ NEVER add .frame(maxHeight:) here — AppDelegate clamps via maxHeight
//   ❌ NEVER add .frame(height:) here
//   ✅ .frame(maxWidth: .infinity) is safe — width axis only
//
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: RunnerStoreObservable.reload() uses withAnimation(nil).
//
// RULE 5: The 5 s timer calls LocalRunnerStore.shared.refresh() + store.reload().
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
// RULE 6: systemStats MUST be paused while the popover is open.
//   SystemStatsViewModel fires every 2 s, mutating @StateObject → SwiftUI re-render
//   → intrinsicContentSize update while popover is shown. Under sizingOptions=[]
//   this is harmless (hosting controller never auto-writes contentSize). Still
//   paused to avoid unnecessary CPU burn while popover is visible.
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
struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void

    // ⚠️ RULE 6 — LIVE open-state signal from @EnvironmentObject.
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

    var body: some View {
        // ⚠️ RULE 1: NO frame constraints here other than maxWidth:.infinity.
        // AppDelegate.openPopover() sets frame to (fixedWidth, 9999), forces layout,
        // reads fittingSize.height, clamps, then sets contentSize ONCE before show().
        // Any idealWidth, fixedSize, or maxHeight here would corrupt that measurement.
        // ❌ NEVER add .frame(idealWidth:), .fixedSize(), or .frame(maxHeight:) here.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
        // is major major major.
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
            actionsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        // ⚠️ RULE 6 — systemStats gate via LIVE @EnvironmentObject.
        // ❌ NEVER change to a plain Bool prop — see RULE 6 comment above.
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

    // MARK: - Runner refresh timer (RULE 5)
    private func startRunnerRefreshTimer() {
        stopRunnerRefreshTimer()
        runnerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            // ⚠️ RULE 5 — timer guard via LIVE @EnvironmentObject.
            // ❌ NEVER remove this guard (RULE 5).
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
    // ⚠️ NO .fixedSize(), NO .frame(maxHeight:) on this section.
    // Under Architecture 2, fittingSize must see the full natural height.
    // AppDelegate.maxHeight (75% screen height) is the only cap, applied in openPopover().
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
