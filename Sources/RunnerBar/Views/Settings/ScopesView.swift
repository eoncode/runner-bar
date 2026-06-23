// ScopesView.swift
// RunnerBar
import RunnerBarCore
import SwiftUI

// MARK: - ScopesView

/// Full scope-management screen, reached from the "Manage scopes" row in Settings.
///
/// Owns all scope-specific state and sheet presentation that previously lived in `SettingsView`.
/// Presented by `SettingsView` via a `showScopes` flag using the same back-callback
/// pattern established by the rest of the panel navigation model.
///
/// No `onRestartPolling` callback is needed — all `ScopeStore` mutations
/// (add, remove, enable/disable) are observed by `RunnerStore`'s
/// `withObservationTracking` loop, which restarts the poll task automatically.
@MainActor
struct ScopesView: View {

    // MARK: - Inputs

    /// Callback invoked when the user taps the back button.
    let onBack: () -> Void
    /// Injected preferences store. Defaults to the shared live instance in
    /// production; swap for a fake in tests.
    private let scopePrefs: any ScopePreferencesStoreProtocol

    // MARK: - Observed stores

    /// Registered remote runner scopes (org / repo URLs).
    @State private var scopeStore = ScopeStore.shared

    // MARK: - Local UI state

    /// Controls presentation of `AddScopeSheet`.
    @State private var showAddScopeSheet = false
    /// Non-nil while `ScopeEditSheet` is presented for this scope entry.
    @State private var selectedScopeEntry: ScopeEntry?
    /// Pre-fetched preferences snapshot for `selectedScopeEntry`.
    /// Populated just before the sheet opens; cleared on dismiss.
    @State private var selectedInitialPrefs: ScopePreferences?

    // MARK: - Init

    init(
        onBack: @escaping () -> Void,
        scopePrefs: any ScopePreferencesStoreProtocol = ScopePreferencesStore.Live.shared
    ) {
        self.onBack = onBack
        self.scopePrefs = scopePrefs
    }

    // MARK: - Body

    /// Root layout: fixed header bar above a scrollable scope list.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                contentStack
                    .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(idealWidth: 480, maxWidth: .infinity)
        .sheet(isPresented: $showAddScopeSheet) {
            AddScopeSheet(isPresented: $showAddScopeSheet)
        }
        // Sheet is driven by selectedScopeEntry; only opens when initialPrefs is
        // also available (both are set atomically in openEditSheet).
        .sheet(item: $selectedScopeEntry) { entry in
            if let initialPrefs = selectedInitialPrefs {
                // #992: ScopeEditSheet replaces the old nav drill-down.
                // #1540: Pass pre-fetched initialPrefs + injected scopePrefs.
                ScopeEditSheet(
                    scopeEntry: entry,
                    initialPrefs: initialPrefs,
                    isPresented: Binding(
                        get: { selectedScopeEntry != nil },
                        set: { if !$0 {
                            selectedScopeEntry = nil
                            selectedInitialPrefs = nil
                        }}
                    ),
                    scopePrefs: scopePrefs
                )
            } else {
                // `selectedInitialPrefs` should always be populated by `openEditSheet`
                // before SwiftUI presents this sheet. A nil value here is a programmer
                // error — fail fast in debug builds so the bug surfaces immediately.
                //
                // Do NOT "clean up" this pattern — removing it silently suppresses
                // the fail-fast behaviour and leaves the user with a blank sheet.
                let msg = "ScopesView: sheet presented with nil selectedInitialPrefs "
                    + "for scope \(entry.scope) — openEditSheet must set both "
                    + "selectedInitialPrefs and selectedScopeEntry atomically."
                _ = assertionFailure(msg)
                EmptyView()
            }
        }
    }

    // MARK: - Header

    /// Top bar with back button and "Manage scopes" title.
    private var headerBar: some View {
        HStack {
            Button(action: onBack, label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                    Text("Manage scopes").font(.headline)
                }
                .foregroundColor(.primary)
            })
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 8)
    }

    // MARK: - Content

    /// Vertical stack of the section header and scope list.
    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            descriptionLabel
            scopeList
        }
    }

    /// Section header row with add button.
    private var sectionHeader: some View {
        HStack {
            Text("Remote runner scopes")
                .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            Spacer()
            Button {
                showAddScopeSheet = true
            } label: {
                Image(systemName: "plus").font(.caption).foregroundColor(Color.rbTextSecondary)
            }
            .buttonStyle(.plain)
            .help("Add a remote scope")
            .accessibilityIdentifier("addScopeButton")
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 2)
    }

    /// Subtitle describing what remote scopes are.
    private var descriptionLabel: some View {
        Text("GitHub repos or orgs whose runners are fetched via the API.")
            .font(.caption).foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md).padding(.bottom, 6)
    }

    /// Empty-state placeholder or populated list of scope rows.
    @ViewBuilder
    private var scopeList: some View {
        if scopeStore.entries.isEmpty {
            Text("No remote scopes added")
                .font(.caption).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 4)
        } else {
            ForEach(scopeStore.entries) { entry in scopeRow(entry) }
        }
    }

    // MARK: - Actions

    /// Pre-fetches `ScopePreferences` for `entry` and opens `ScopeEditSheet`.
    ///
    /// Both `selectedInitialPrefs` and `selectedScopeEntry` are assigned
    /// synchronously on `@MainActor` before the run loop yields, so SwiftUI
    /// cannot observe `selectedScopeEntry != nil` while `selectedInitialPrefs`
    /// is still nil. If `preferences(for:)` ever becomes async this function
    /// must also become `async` to preserve the invariant at the type level.
    private func openEditSheet(for entry: ScopeEntry) {
        let prefs = scopePrefs.preferences(for: entry.scope)
        selectedInitialPrefs = prefs
        selectedScopeEntry = entry
    }

    // MARK: - Scope rows

    /// Row view for a single remote scope entry.
    private func scopeRow(_ entry: ScopeEntry) -> some View {
        let isRepo = entry.scope.contains("/")
        let displayName = scopePrefs.displayName(for: entry.scope)
        return Button {
            openEditSheet(for: entry)
        } label: {
            HStack(spacing: 8) {
                Text(isRepo ? "Repo" : "Org")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.rbSurfaceElevated))
                    .overlay(Capsule().strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Show the raw scope as a subtitle only when the display name differs.
                    if displayName != entry.scope {
                        Text(entry.scope)
                            .font(.caption2)
                            .foregroundColor(Color.rbTextTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                Text(entry.isEnabled ? "Active" : "Paused")
                    .font(.caption2)
                    .foregroundColor(entry.isEnabled ? Color.rbSuccess : Color.rbTextTertiary)
                Toggle("", isOn: Binding(
                    get: { entry.isEnabled },
                    // ScopeStore enable/disable is observed by RunnerStore.startObservingScopes
                    // via withObservationTracking — no explicit restart needed here.
                    set: { scopeStore.setEnabled(entry.id, $0) }
                ))
                .toggleStyle(.switch)
                .tint(Color.rbSuccess)
                .labelsHidden()
                .help(entry.isEnabled ? "Pause monitoring" : "Resume monitoring")
                .scaleEffect(0.8, anchor: .trailing)
                .buttonStyle(.borderless)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextTertiary)
                Button {
                    // #1540: route cleanUp through the injected store so the view
                    // layer contains zero direct ScopePreferencesStore static calls.
                    scopePrefs.removePreferences(for: entry.scope)
                    scopeStore.remove(id: entry.id)
                    // ScopeStore.remove mutates activeScopes, firing withObservationTracking
                    // in startObservingScopes and restarting the poll loop automatically.
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.caption2)
                        .foregroundColor(Color.rbDanger)
                }
                .buttonStyle(.borderless)
                .help("Remove scope")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 5)
        .glassCard(cornerRadius: RBRadius.small)
        .padding(.horizontal, RBSpacing.xs)
        .opacity(entry.isEnabled ? 1.0 : 0.5)
    }
}
