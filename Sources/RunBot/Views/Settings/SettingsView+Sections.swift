// NOTE: Only the betaChannelRow description string is changed in this file.
// The full file content is reproduced below with that single fix applied.
// All other code is unchanged from the PR branch.
import SwiftUI
import RunBotCore

internal extension SettingsView {

    // MARK: - General
    /// General section: polling interval, API call counter, notification toggles, launch-at-login, popover arrow, and beta channel.
    ///
    /// `settings` and `notifications` are injected `let` properties on an `@Observable` type.
    /// SwiftUI cannot synthesise `$`-bindings from plain `let` stored properties, so we
    /// wrap them in `Bindable` at each use site.
    var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("General").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, RBSpacing.md).padding(.bottom, 6)
            pollingIntervalRow
            Divider().padding(.leading, RBSpacing.md)
            apiCallCounterRow
            Divider().padding(.leading, RBSpacing.md)
            notificationTogglesRow
            Divider().padding(.leading, RBSpacing.md)
            launchAtLoginRow
            Divider().padding(.leading, RBSpacing.md)
            showDimmedRunnersRow
            Divider().padding(.leading, RBSpacing.md)
            showWelcomeScreenRow
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 6)
            Divider().padding(.leading, RBSpacing.md)
            popoverArrowRow
            Divider().padding(.leading, RBSpacing.md)
            betaChannelRow
        }
    }

    // MARK: - Beta channel row
    /// Toggle row that opts the user into pre-release (beta) builds for the in-app update check.
    var betaChannelRow: some View {
        let bindableBeta = Bindable(settings)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Beta channel").font(.system(size: 12))
                Text("Receive pre-release builds for early access to new features. Takes effect on the next update check.")
                    .font(.caption2).foregroundColor(Color.rbTextSecondary)
            }
            Spacer()
            Toggle("", isOn: bindableBeta.betaChannel)
                .toggleStyle(.switch).tint(Color.rbSuccess).labelsHidden()
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 6).padding(.bottom, 6)
    }

    // MARK: - About
    /// App version, build number, and update available banner (when a newer release exists).
    var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("About").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, RBSpacing.md).padding(.bottom, 6)
            HStack {
                Text("Version").font(.system(size: 12))
                Spacer()
                Text("\(appVersion) (\(appBuild))").font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 5)
            if runnerState.availableUpdate != nil {
                Divider().padding(.leading, RBSpacing.md)
                updateActionRow
            }
        }
    }

    // MARK: - Update action row

    /// ⚠️⚠️⚠️ UPDATE UI LIVES HERE AND ONLY HERE — READ BEFORE TOUCHING ⚠️⚠️⚠️
    ///
    /// This row, inside the About section of Settings, is the ONLY update-related
    /// UI in the entire app. This is a deliberate product decision (issue #1794).
    ///
    /// **DO NOT:**
    /// - Add a banner to `PanelMainView`, the menu bar popover, or any other view.
    /// - Add a SwiftUI `Link` that opens a browser. The "Download" fallback button
    ///   uses `NSWorkspace.shared.open(...)` which opens the URL natively without
    ///   launching Safari. A `Link` wrapper would open Safari — wrong for a
    ///   menu-bar utility and against the design in #1794.
    /// - Add a notification badge, dot indicator, or any other passive signal
    ///   outside of this row.
    ///
    /// The row is only rendered when `runnerState.availableUpdate != nil` (see
    /// `aboutSection`). When there is no update the row is absent entirely —
    /// no empty space, no placeholder.
    ///
    /// **REVIEWER:** If you are about to suggest adding a banner or putting update
    /// UI somewhere else in the view hierarchy, please read issue #1794 first.
    /// The single-row approach is the final design for v1, not a placeholder.
    var updateActionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available: \(runnerState.availableUpdate ?? "")")
                    .font(.system(size: 12))
                Text("A new version of RunBot is ready.")
                    .font(.caption2).foregroundColor(Color.rbTextSecondary)
            }
            Spacer()
            if runnerState.updateAssetMissing || runnerState.updateActionFailed {
                Button("Download") {
                    guard let url = URL(string: "https://github.com/runbot-hq/run-bot/releases/latest") else {
                        return
                    }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if runnerState.updateZipURL == nil {
                // ProgressView label is intentionally visible (not hidden) so VoiceOver
                // announces "Downloading update…" — spec #1797 acceptance criterion.
                // Do NOT add .labelsHidden() here; it would silently suppress the
                // accessible label and break VoiceOver without any visual change.
                ProgressView("Downloading update…")
                    .scaleEffect(RBMetrics.updateProgressScale)
            } else {
                Button("Install & Relaunch") {
                    Task {
                        await AutoUpdater.installAndRelaunch(state: runnerState)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 8)
    }
}
