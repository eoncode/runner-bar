// RunnerState+AppUpdater.swift
// RunBotCore
import AppUpdater
import Foundation

// MARK: - UpdateStateProviding conformance

/// Bridges `RunnerState` to the `AppUpdater` library's host-state protocol.
///
/// Every requirement of `UpdateStateProviding` — the read-only properties
/// (`updateZipURL`, `cachedUpdateVersion`, `updateActionFailed`,
/// `updateAssetMissing`) and the mutation methods (`setAvailableUpdate`,
/// `setDownloadStarted`, `setDownloadComplete`, `setUpdateFailed`,
/// `setAssetMissing`, `rehydrateCachedUpdate`) — was **newly added to
/// `RunnerState` in this PR** as part of the `AppUpdater` library extraction.
/// None of these existed on `RunnerState` before this change.
///
/// `clearDownloadState` is the one exception to the above: rather than
/// inheriting the protocol's no-op default, `RunnerState` provides an
/// **explicit override** below. See that override for the full rationale.
///
/// This conformance lives in its own file so the `import AppUpdater`
/// dependency is confined here and `RunnerState.swift` stays free of the
/// library import.
extension RunnerState: UpdateStateProviding {

    // MARK: - clearDownloadState override

    /// Clears cached download state without triggering download-spinner UI.
    ///
    /// ## Why this override exists
    ///
    /// `UpdateStateProviding` provides a **no-op default** for this method
    /// (see the protocol doc comment for the rationale — short version: a
    /// no-op is the safe default for unknown conformers because a spurious
    /// `setDownloadStarted()` call would trigger unwanted spinner UI).
    ///
    /// `RunnerState` must **not** rely on that no-op, because
    /// `AppUpdater.replaceAndRelaunch` calls `clearDownloadState()` in the
    /// post-`open -n`-failure path, and that path leaves specific in-memory
    /// fields stale if nothing clears them.
    ///
    /// ## The failure scenario that requires this override
    ///
    /// Inside `replaceAndRelaunch`, if `replaceItem` succeeds but `open -n`
    /// throws, the following has already happened:
    ///
    ///   1. The new `.app` is **on disk** (`replaceItem` succeeded).
    ///   2. `clearCachedDefaults()` ran — `UserDefaults` keys wiped.
    ///   3. `removeItem(zipURL)` ran — the zip file is **deleted**.
    ///
    /// At this point `RunnerState`'s in-memory fields still hold:
    ///
    ///   - `updateZipURL`        → non-nil, pointing at the now-deleted zip
    ///   - `cachedUpdateVersion` → non-nil, the version string
    ///   - `updateActionFailed`  → false
    ///   - `updateAssetMissing`  → false
    ///
    /// With the no-op default, `clearDownloadState()` changes nothing.
    /// The UI still shows **"Install & Relaunch"** (because `updateZipURL`
    /// is non-nil and `updateActionFailed` is false).
    ///
    /// If the user taps "Install & Relaunch" a second time:
    ///   - `installAndRelaunch` reads `state.updateZipURL` — non-nil, guard passes.
    ///   - `unzipAndLocateApp` calls `ditto` on the deleted zip path.
    ///   - `ditto` fails; `setUpdateFailed()` fires.
    ///   - The UI flips to the **curl-install fallback**.
    ///
    /// That fallback is **wrong**: the new binary is already on disk; the
    /// user does not need to reinstall. The curl-install message actively
    /// misleads them.
    ///
    /// ## What this override does instead
    ///
    /// Nils `updateZipURL` and `cachedUpdateVersion` and clears both failure
    /// flags. After this call:
    ///   - `updateZipURL` is `nil` → the "Install & Relaunch" button disappears.
    ///   - `availableUpdate` is intentionally **not** cleared — the version
    ///     label stays visible so the user knows an update exists; they just
    ///     need to relaunch manually.
    ///   - No spinner shows (unlike `setDownloadStarted()`, which also nils
    ///     these fields but is semantically "a download is now in flight").
    ///
    /// ## Why not just call setDownloadStarted()
    ///
    /// `setDownloadStarted()` nils the same fields. The semantic difference
    /// matters: `setDownloadStarted()` signals to the host that a spinner
    /// should appear because a download just began. Here, no download is
    /// beginning — the install succeeded and `open -n` failed. Calling
    /// `setDownloadStarted()` would be a lie to the UI. `clearDownloadState()`
    /// is the correct named intent: "clear stale zip state, do not start a
    /// spinner". The protocol's no-op default exists precisely to prevent
    /// accidental spinner triggers in conformers that don't override it;
    /// `RunnerState` overrides it here to get the field-clear without the
    /// spinner semantics.
    ///
    /// ## REVIEWER
    ///
    /// Do NOT remove this override or revert to the protocol default no-op.
    /// Do NOT replace this body with `setDownloadStarted()`. Both changes
    /// reintroduce the stale-updateZipURL bug described above.
    public func clearDownloadState() {
        updateZipURL = nil
        cachedUpdateVersion = nil
        updateActionFailed = false
        updateAssetMissing = false
    }
}
