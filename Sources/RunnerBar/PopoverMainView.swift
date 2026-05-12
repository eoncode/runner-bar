import SwiftUI
// swiftlint:disable opening_brace

// ⚠️ REGRESSION GUARD — frame + padding rules (ref #52 #54 #57 #296)
//
// RULE 1: Root VStack MUST use .frame(width: 420, alignment: .topLeading)
//         ❌ NEVER use .frame(maxWidth: .infinity) — it conflicts with the outer
//         .fixedSize(horizontal: false, vertical: true) applied by AppDelegate,
//         causing SwiftUI to collapse the view height to zero (ref #381).
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: NEVER use .fixedSize() on any container inside PopoverMainView.
// RULE 5: RunnerStoreObservable.reload() uses withAnimation(nil).
//
// HEIGHT REPORTING (ref #377 — Architecture 2b):
//   PopoverMainView reports its own rendered height via HeightPreferenceKey.
//   AppDelegate reads this via .onPreferenceChange and stores it in measuredHeight.
//   openPopover() uses measuredHeight directly — fittingSize is NEVER used.
//   ❌ NEVER switch back to fittingSize — it returns cached/stale values with sizingOptions=[].
//   ❌ NEVER remove the .background(GeometryReader) + HeightPreferenceKey machinery.
//   If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
//   UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
//   is major major major.
//
// SCROLLVIEW RULE (#296):
//   ❌ NEVER wrap ActionsListView in a ScrollView with a fixed maxHeight.
//
// EMPTY STATE RULE (#377):
//   The empty-state path ("No recent actions") MUST have a minHeight: 120
//   on its container so GeometryReader reports a realistic height and Phase 2
//   does not clamp to minHeight while leaving content tiny + centred.
//   ❌ NEVER remove the .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
//   from ActionsListView empty branch.
//
// HEADER HEIGHT RULE (ref #misalignment):
//   PopoverHeaderView MUST have .frame(height: 32) to prevent collapse.
//   ❌ NEVER add .fixedSize() to statChip calls — it interacts badly with the
//   outer .fixedSize(horizontal:false, vertical:true) from AppDelegate and causes
//   the header to report zero height, hiding all header content.
//
// MODEL API — verified against source files, DO NOT hallucinate properties:
//   ActionGroup:    .progressFraction (Double?), .headBranch (String?), .elapsed (String),
//                   .groupStatus (GroupStatus), .conclusion (String?), .title, .repo, .jobs
//   PieProgressView: init(progress: Double?, color: Color, size: CGFloat = 8)
//                   ❌ NO status: parameter — it does not exist
//   ActiveJob:      .name, .status, .conclusion, .elapsed (String computed var)
//                   ❌ NO .elapsedLabel — the property is .elapsed
//                   ❌ NO .progress — use .progressFraction
//   Runner:         .status is String ("online"/"offline"), .busy (Bool), .displayStatus (String)
//                   ❌ NO .statusLabel, NO enum cases .online/.offline/.busy

// MARK: - HeightPreferenceKey

/// SwiftUI preference key used to report the popover's rendered height to AppDelegate.
/// AppDelegate reads this via .onPreferenceChange on the root hosting view.
///
/// ⚠️ REDUCER MUST BE REPLACE, NOT MAX (ref #379):
///   Using max() causes the first measurement (during off-screen layout at
///   unconstrainedHeight=2000) to lock the value at 2000 permanently.
///   A replace reducer always reflects the latest layout pass height.
/// ❌ NEVER change reduce to max(value, nextValue()) — it breaks dynamic height.
/// ❌ NEVER remove — this is the height-measurement mechanism (replaces fittingSize).
/// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
/// UNDER ANY CIRCUMSTANCE.
struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Layout constants

private enum PopoverLayout {
    static let idealWidth: CGFloat = 420
    /// Explicit header height — prevents collapse when outer fixedSize is applied.
    static let headerHeight: CGFloat = 32
}

/// Root popover view. Reports its own rendered height via HeightPreferenceKey.
struct PopoverMainView: View {
    @ObservedObject var store: RunnerStoreObservable
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void

    @State private var isAuthenticated = (githubToken() != nil)
    @StateObject private var systemStats = SystemStatsViewModel()
    @State private var visibleCount: Int = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeaderView(
                systemStats: systemStats,
                isAuthenticated: isAuthenticated,
                onSelectSettings: onSelectSettings
            )
            Divider()
            if store.isRateLimited {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow).font(.caption)
                    Text("GitHub rate limit reached — pausing polls")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                Divider()
            }
            RunnersListView(runners: store.runners)
            ActionsListView(
                actions: store.actions,
                visibleCount: $visibleCount,
                onSelectAction: onSelectAction
            )
        }
        // ⚠️ RULE 1: exact width=420, NOT maxWidth:.infinity.
        .frame(width: PopoverLayout.idealWidth, alignment: .topLeading)
        // ⚠️ HEIGHT REPORTING: measure rendered height and publish via HeightPreferenceKey.
        // ❌ NEVER remove this .background modifier.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: HeightPreferenceKey.self, value: geo.size.height)
            }
        )
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            systemStats.start()
        }
        .onDisappear { systemStats.stop() }
        .onChange(of: store.actions) { _ in
            if visibleCount > 10 { visibleCount = 10 }
        }
    }
}

// MARK: - MiniBarView

private struct MiniBarView: View {
    let fraction: Double
    var width: CGFloat = 22
    var height: CGFloat = 6

    private var clampedFraction: Double { max(0, min(1, fraction)) }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.primary.opacity(0.12))
                .frame(width: width, height: height)
            RoundedRectangle(cornerRadius: 1)
                .fill(barColor)
                .frame(width: CGFloat(clampedFraction) * width, height: height)
        }
    }

    private var barColor: Color {
        if clampedFraction > 0.85 { return .red }
        if clampedFraction > 0.60 { return .yellow }
        return .green
    }
}

// MARK: - PopoverHeaderView

private struct PopoverHeaderView: View {
    let systemStats: SystemStatsViewModel
    let isAuthenticated: Bool
    let onSelectSettings: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            statChip(
                label: "CPU",
                fraction: systemStats.stats.cpuPct / 100,
                value: String(format: "%.1f%%", systemStats.stats.cpuPct)
            )
            statChip(
                label: "MEM",
                fraction: systemStats.stats.memTotalGB > 0
                    ? systemStats.stats.memUsedGB / systemStats.stats.memTotalGB : 0,
                value: String(format: "%.1f/%.0fGB",
                              systemStats.stats.memUsedGB, systemStats.stats.memTotalGB)
            )
            statChip(
                label: "DISK",
                fraction: systemStats.stats.diskTotalGB > 0
                    ? systemStats.stats.diskUsedGB / systemStats.stats.diskTotalGB : 0,
                value: String(format: "%.0f/%.0fGB",
                              systemStats.stats.diskUsedGB, systemStats.stats.diskTotalGB)
            )
            Spacer(minLength: 0)
            if !isAuthenticated {
                Button(
                    action: onSelectSettings,
                    label: {
                        HStack(spacing: 4) {
                            Circle().fill(Color.orange).frame(width: 7, height: 7)
                            Text("Sign in").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                )
                .buttonStyle(.plain)
                .help("Not authenticated — open Settings to add a GitHub token")
            }
            Button(
                action: onSelectSettings,
                label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain)
            .help("Settings")
            Button(
                action: { NSApplication.shared.hide(nil) },
                label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            )
            .buttonStyle(.plain)
            .help("Close popover")
        }
        .padding(.horizontal, 12)
        // ⚠️ HEADER HEIGHT RULE: explicit frame height prevents collapse under outer
        // fixedSize(horizontal:false, vertical:true) applied by AppDelegate.
        // ❌ NEVER remove this .frame(height:) — without it the header disappears.
        .frame(height: PopoverLayout.headerHeight)
    }

    @ViewBuilder
    private func statChip(label: String, fraction: Double, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            MiniBarView(fraction: fraction)
            Text(value).font(.caption2.monospacedDigit()).foregroundColor(.primary)
        }
    }
}

// MARK: - ActionsListView

private struct ActionsListView: View {
    let actions: [ActionGroup]
    @Binding var visibleCount: Int
    let onSelectAction: (ActionGroup) -> Void

    var body: some View {
        if actions.isEmpty {
            // ⚠️ EMPTY STATE MIN HEIGHT (ref #377):
            // ❌ NEVER remove .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            Text("No recent actions")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        } else {
            VStack(spacing: 0) {
                ForEach(actions.prefix(visibleCount)) { actionGroup in
                    ActionRowView(
                        actionGroup: actionGroup,
                        onSelect: { onSelectAction(actionGroup) }
                    )
                }
                if actions.count > visibleCount {
                    Button(
                        action: { visibleCount += 10 },
                        label: {
                            Text("Load 10 more actions\u{2026}")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    )
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                } else if visibleCount > 10 {
                    Text("No more actions")
                        .font(.caption2).foregroundColor(.secondary.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                }
            }
            .padding(.bottom, 6)
        }
    }
}

// MARK: - ActionRowView

private struct ActionRowView: View {
    let actionGroup: ActionGroup
    let onSelect: () -> Void

    private var inlineJobs: [ActiveJob] {
        guard actionGroup.groupStatus == .inProgress else { return [] }
        return actionGroup.jobs.filter { $0.status == "in_progress" }
    }

    private var pieColor: Color {
        switch actionGroup.groupStatus {
        case .inProgress: return .blue
        case .queued:     return .yellow
        case .completed:
            switch actionGroup.conclusion {
            case "success":   return .green
            case "failure":   return .red
            case "cancelled": return Color(nsColor: .systemOrange)
            default:          return .secondary
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(
                action: onSelect,
                label: {
                    HStack(spacing: 6) {
                        PieProgressView(
                            progress: actionGroup.progressFraction,
                            color: pieColor
                        )
                        .frame(width: 14, height: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(actionGroup.title)
                                .font(.caption.weight(.medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(actionGroup.repo)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                if let branch = actionGroup.headBranch {
                                    Text("·").font(.caption2).foregroundColor(.secondary)
                                    Text(branch)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer()
                        Text(actionGroup.elapsed)
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
            )
            .buttonStyle(.plain)
            if !inlineJobs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(inlineJobs) { job in
                        InlineJobRowView(job: job)
                    }
                }
            }
        }
    }
}

// MARK: - InlineJobRowView

private struct InlineJobRowView: View {
    let job: ActiveJob

    var body: some View {
        HStack(spacing: 6) {
            PieProgressView(progress: job.progressFraction, color: .blue)
                .frame(width: 10, height: 10)
                .padding(.leading, 28)
            Text(job.name)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
            Text(job.elapsed)
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
    }
}

// MARK: - RunnersListView

struct RunnersListView: View {
    let runners: [Runner]

    var body: some View {
        if !runners.isEmpty {
            VStack(spacing: 0) {
                ForEach(runners) { runner in
                    RunnerRowView(runner: runner)
                }
            }
            Divider()
        }
    }
}

// MARK: - RunnerRowView

private struct RunnerRowView: View {
    let runner: Runner

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(runner.name)
                .font(.caption)
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer()
            Text(runner.displayStatus)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch runner.status {
        case "online":  return runner.busy ? .orange : .green
        case "offline": return .red
        default:        return .secondary
        }
    }
}
