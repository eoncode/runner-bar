import SwiftUI

// MARK: - ScopeDetailView
// Navigation level: SettingsView (scope row tap) → ScopeDetailView ← this view
//
// #499: Nav shell + wiring
// #500: Alias text field
// #502: Per-scope polling interval override
// #504: Per-scope notification overrides

struct ScopeDetailView: View {
    let scopeEntry: ScopeEntry
    let onBack: () -> Void

    // #499: Enable toggle (mirrors SettingsView row toggle)
    @ObservedObject private var scopeStore = ScopeStore.shared

    // #500: Alias
    @State private var aliasText: String
    // Cached initial alias so .disabled() on Save never reads UserDefaults on every body pass.
    @State private var savedAlias: String
    @State private var aliasSaved = false

    // #502: Polling interval override
    // nil sentinel = "Use global"; picker values: nil, 10, 15, 30, 60, 120, 300
    @State private var pollingOverride: Int?   // nil = use global
    private let pollingOptions: [(label: String, value: Int?)] = [
        ("Use global", nil),
        ("10 s", 10),
        ("15 s", 15),
        ("30 s", 30),
        ("60 s", 60),
        ("120 s", 120),
        ("300 s", 300),
    ]

    // #504: Notification overrides (nil = use global)
    @State private var notifySuccessOverride: Bool?  // nil = use global
    @State private var notifyFailureOverride: Bool?  // nil = use global

    init(scopeEntry: ScopeEntry, onBack: @escaping () -> Void) {
        self.scopeEntry = scopeEntry
        self.onBack = onBack
        let scope = scopeEntry.scope
        let initialAlias = ScopeSettingsStore.alias(for: scope) ?? ""
        _aliasText = State(initialValue: initialAlias)
        _savedAlias = State(initialValue: initialAlias)
        _pollingOverride = State(initialValue: ScopeSettingsStore.pollingInterval(for: scope))
        _notifySuccessOverride = State(initialValue: ScopeSettingsStore.notifyOnSuccess(for: scope))
        _notifyFailureOverride = State(initialValue: ScopeSettingsStore.notifyOnFailure(for: scope))
    }

    // Live entry from store so enable/disable toggle reflects current state.
    private var liveEntry: ScopeEntry? {
        scopeStore.entries.first(where: { $0.id == scopeEntry.id })
    }
    private var isEnabled: Bool { liveEntry?.isEnabled ?? scopeEntry.isEnabled }
    private var scope: String { scopeEntry.scope }
    private var isRepo: Bool { scope.contains("/") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    infoSection
                    aliasSection
                    pollingSection
                    notificationsSection
                    dangerSection
                }
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(idealWidth: 480, maxWidth: .infinity)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            // Back label reads "‹ Settings" — intentional, mirrors RunnerDetailView.
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.caption)
                    Text("Settings").font(.caption)
                }
                .foregroundColor(Color.rbTextSecondary)
                .fixedSize()
            }
            .buttonStyle(.plain)

            Spacer()

            // Type badge
            Text(isRepo ? "Repo" : "Org")
                .font(.caption2)
                .foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.rbSurfaceElevated))
                .overlay(Capsule().strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))

            Text(ScopeSettingsStore.displayName(for: scope))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)

            Spacer()

            // Enable/disable toggle in header
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { ScopeStore.shared.setEnabled(scopeEntry.id, $0); RunnerStore.shared.start() }
            ))
            .toggleStyle(.switch).labelsHidden()
            .help(isEnabled ? "Pause monitoring this scope" : "Resume monitoring")
            .scaleEffect(0.8, anchor: .trailing)
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Scope Info")
            infoCard {
                infoRow(label: "Scope", value: scope, copyable: true)
                Divider().padding(.leading, RBSpacing.md)
                infoRow(label: "Type", value: isRepo ? "Repository" : "Organisation")
                Divider().padding(.leading, RBSpacing.md)
                infoRow(label: "Monitoring", value: isEnabled ? "Active" : "Paused")
            }
        }
    }

    // MARK: - Alias Section (#500)

    private var aliasSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Friendly Alias")
            infoCard {
                HStack(spacing: 8) {
                    TextField("e.g. My Org", text: $aliasText)
                        .font(.system(size: 12))
                        .textFieldStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .onChange(of: aliasText) { _ in aliasSaved = false }
                    if aliasSaved {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12)).foregroundColor(Color.rbSuccess)
                    } else {
                        Button(action: saveAlias) {
                            Text("Save").font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        // Compare against cached savedAlias — avoids a UserDefaults read on every body pass.
                        .disabled(aliasText.trimmingCharacters(in: .whitespacesAndNewlines) == savedAlias)
                    }
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
            }
            Text("Shown instead of the raw scope string in lists and tooltips. Leave blank to use the scope slug.")
                .font(.caption2).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.bottom, 8)
        }
    }

    // MARK: - Polling Section (#502)

    private var pollingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Polling Interval")
            infoCard {
                HStack {
                    Text("Check every")
                        .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                    Spacer()
                    Picker("", selection: $pollingOverride) {
                        ForEach(pollingOptions, id: \.label) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    // Two-argument form — single-arg onChange(of:) deprecated macOS 14 / Swift 5.9.
                    .onChange(of: pollingOverride) { _, newValue in
                        ScopeSettingsStore.setPollingInterval(newValue, for: scope)
                        RunnerStore.shared.start()
                    }
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
            }
            Text("\"Use global\" follows the global polling interval set in General settings.")
                .font(.caption2).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.bottom, 8)
        }
    }

    // MARK: - Notifications Section (#504)

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Notifications")
            infoCard {
                HStack {
                    Text("Notify on success")
                        .font(.system(size: 12))
                    Spacer()
                    threeStateToggle(
                        value: $notifySuccessOverride,
                        onChange: { ScopeSettingsStore.setNotifyOnSuccess($0, for: scope) }
                    )
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                Divider().padding(.leading, RBSpacing.md)
                HStack {
                    Text("Notify on failure")
                        .font(.system(size: 12))
                    Spacer()
                    threeStateToggle(
                        value: $notifyFailureOverride,
                        onChange: { ScopeSettingsStore.setNotifyOnFailure($0, for: scope) }
                    )
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
            }
            Text("\"Global\" follows the Notifications setting. Override per scope with On or Off.")
                .font(.caption2).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.bottom, 8)
        }
    }

    // MARK: - Danger Section

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Danger Zone")
            infoCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remove scope")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.rbDanger)
                        Text("Stops monitoring this scope. Runners already discovered are not affected.")
                            .font(.caption2).foregroundColor(Color.rbTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(action: removeScope) {
                        Text("Remove").font(.caption2).foregroundColor(Color.rbDanger)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 10)
            }
        }
    }

    // MARK: - Three-state toggle (#504)
    // nil = Global (inherits), true = On, false = Off
    // Cycles: nil → true → false → nil

    @ViewBuilder
    private func threeStateToggle(value: Binding<Bool?>, onChange: @escaping (Bool?) -> Void) -> some View {
        HStack(spacing: 4) {
            Button(action: {
                let next: Bool? = {
                    switch value.wrappedValue {
                    case nil:   return true
                    case true:  return false
                    case false: return nil
                    default:    return nil
                    }
                }()
                value.wrappedValue = next
                onChange(next)
            }) {
                Text(label(for: value.wrappedValue))
                    .font(.caption2)
                    .foregroundColor(foreground(for: value.wrappedValue))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(
                        Capsule().fill(background(for: value.wrappedValue))
                    )
            }
            .buttonStyle(.plain)
            .help("Tap to cycle: Global → On → Off")
        }
    }

    private func label(for value: Bool?) -> String {
        switch value {
        case nil:   return "Global"
        case true:  return "On"
        case false: return "Off"
        default:    return "Global"
        }
    }

    private func foreground(for value: Bool?) -> Color {
        switch value {
        case nil:   return Color.rbTextSecondary
        case true:  return Color.rbSuccess
        case false: return Color.rbDanger
        default:    return Color.rbTextSecondary
        }
    }

    private func background(for value: Bool?) -> Color {
        switch value {
        case nil:   return Color.rbSurfaceElevated
        case true:  return Color.rbSuccess.opacity(0.12)
        case false: return Color.rbDanger.opacity(0.12)
        default:    return Color.rbSurfaceElevated
        }
    }

    // MARK: - Actions

    private func saveAlias() {
        let trimmed = aliasText.trimmingCharacters(in: .whitespacesAndNewlines)
        ScopeSettingsStore.setAlias(trimmed.isEmpty ? nil : trimmed, for: scope)
        // Update cached value so Save button disables immediately after saving.
        savedAlias = trimmed
        aliasSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { aliasSaved = false }
    }

    private func removeScope() {
        ScopeSettingsStore.cleanUp(scope: scope)
        // ScopeStore.remove is synchronous and fires onMutate → observable.reload() before
        // returning, so the scope is fully gone from the live store before start() polls.
        // No removed-scope poll window exists.
        ScopeStore.shared.remove(id: scopeEntry.id)
        RunnerStore.shared.start()
        onBack()
    }

    // MARK: - Sub-view helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 4)
    }

    private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: RBRadius.small)
                    .fill(Color.rbSurfaceElevated)
                    .overlay(RoundedRectangle(cornerRadius: RBRadius.small)
                        .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))
            )
            .padding(.horizontal, RBSpacing.md)
            .padding(.bottom, 8)
    }

    private func infoRow(label: String, value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading).fixedSize()
            Text(value)
                .font(.system(size: 12, design: .monospaced)).foregroundColor(Color.rbTextPrimary)
                .lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copyable {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(Color.rbTextTertiary)
                }
                .buttonStyle(.plain).help("Copy to clipboard")
            }
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
    }
}
