// RunnerState.swift
// RunBotCore
import Foundation
import Observation

// MARK: - RunnerState

/// Observable read model populated by `RunnerPoller` and consumed by the app layer.
///
/// All mutations happen on the `MainActor`. Views and `AppDelegate` observe this
/// object directly via `withObservationTracking` or `ObservationLoop`.
///
/// The six poll-written properties (`runners`, `jobs`, `actions`, `isRateLimited`,
/// `rateLimitResetDate`, `fetchError`) are `public internal(set)` — only
/// `RunnerPoller.applyFetchResult` (same module) should mutate them.
/// Two additional properties (`localRunners`, `isLocalScanning`) are `public var`
/// because Swift requires the setter to match the accessibility of a `public` protocol
/// `{ get set }` requirement — see `RunnerViewModelProtocol` for the rationale.
/// Only `LocalRunnerStore` (in `RunBotCore`) writes them in practice.
/// The auto-update download properties (`updateZipURL`, `cachedUpdateVersion`,
/// `updateAssetMissing`, `updateActionFailed`) are `public internal(set)` for
/// reads, but are written by `AppUpdater` (in the `AppUpdater` module) through
/// the `UpdateStateProviding` mutation methods below. `RunnerState` conforms to
/// that protocol in `RunnerState+AppUpdater.swift`.
/// Views and app-layer code are read-only consumers of all properties.
@Observable
@MainActor
public final class RunnerState {

    // MARK: - Poll-written runner state (pushed by RunnerPoller)

    /// The current list of GitHub self-hosted runners for all active scopes.
    public internal(set) var runners: [Runner] = []

    /// Active and recently-completed jobs across all active scopes.
    public internal(set) var jobs: [ActiveJob] = []

    /// Workflow action groups (runs) across all active scopes.
    public internal(set) var actions: [WorkflowActionGroup] = []

    /// Whether the GitHub API rate limit has been hit.
    ///
    /// When `true`, polling is paused until `rateLimitResetDate`.
    public internal(set) var isRateLimited = false

    /// The date at which the rate limit resets, if currently rate-limited.
    public internal(set) var rateLimitResetDate: Date?

    /// The most recent fetch error, or `nil` if the last fetch succeeded.
    ///
    /// Set by `RunnerPoller.applyError(_:)`; cleared on every successful
    /// `applyFetchResult`. Views read this to show a non-modal error banner.
    ///
    /// Typed `(any Error)?` — the stored value is always a `RunnerPoller.FetchError`,
    /// which is `Sendable`. The property stays `any Error` for display flexibility;
    /// `@MainActor` isolation on `RunnerState` ensures safe cross-actor reads.
    public internal(set) var fetchError: (any Error)?

    // MARK: - Local runner state (pushed by LocalRunnerStore)

    /// Locally-installed runner agents discovered on this Mac.
    ///
    /// Pushed by `LocalRunnerStore` via `await MainActor.run { }` after every refresh cycle.
    ///
    /// Declared `public var` (not `public internal(set) var`) because Swift requires the
    /// setter to be at least as accessible as the protocol requirement when conforming to a
    /// public protocol with a `{ get set }` requirement. `public internal(set)` would restrict
    /// the setter to `RunBotCore` and fail to satisfy the requirement at the module interface.
    /// In practice, only `LocalRunnerStore` (inside `RunBotCore`) ever writes this property;
    /// the `public` setter is a type-system necessity, not an invitation for external mutation.
    public var localRunners: [RunnerModel] = []

    /// `true` while `LocalRunnerStore` is running a refresh cycle.
    ///
    /// Pushed by `LocalRunnerStore` alongside `localRunners`.
    /// See `localRunners` for the access-level rationale.
    public var isLocalScanning: Bool = false

    /// The overall connectivity state of the runner fleet, derived from `runners`.
    /// Observed by `AppDelegate`'s `statusIconLoop` via `ObservationLoop`.
    public var aggregateStatus: AggregateStatus {
        AggregateStatus(runners: runners)
    }

    // MARK: - Init

    /// Public memberwise-style initialiser required so that `RunnerPollerProtocol`
    /// can use `RunnerState()` as a default argument value from another module
    /// (`RunBot` app target). Without an explicit `public init()`, the
    /// `@Observable`-synthesised initialiser is `internal` and the cross-module
    /// default argument fails to compile.
    public init() {}

    // MARK: - Auto-update state (driven by AppUpdater via UpdateStateProviding)

    /// The latest available version string if a newer version exists, or `nil` if
    /// up to date.
    ///
    /// **Read-only for all callers.** Write via `setAvailableUpdate(_:)` below.
    public private(set) var availableUpdate: String?

    /// Sets `availableUpdate`.
    ///
    /// Called from `AppUpdater.handle(_:state:)` on every `.updateAvailable` result
    /// (including the launch-time check in `AppDelegate+PanelSetup`) and from
    /// `AppUpdater.scheduleBackgroundCheck` to clear a stale row on `.upToDate`
    /// or `.failed` results (when no zip is cached).
    ///
    /// Using an explicit method (rather than direct property assignment) keeps
    /// every write site visible in code review and prevents ad-hoc mutation elsewhere.
    public func setAvailableUpdate(_ version: String?) {
        availableUpdate = version
    }

    /// Local file URL of the cached `RunBot-update.zip`, or `nil` while the
    /// download is in progress or has not started yet.
    ///
    /// The Install & Relaunch button is shown only when this is non-nil.
    public internal(set) var updateZipURL: URL?

    /// Version string of the cached update zip (e.g. `"v0.8.0"`), or `nil`
    /// if no download has been cached yet.
    public internal(set) var cachedUpdateVersion: String?

    /// Rehydrates cached download state from `UserDefaults` on startup.
    ///
    /// Called by `AppUpdater.rehydrateCachedUpdateIfNewer` after verifying the
    /// cached zip still exists on disk and its version is newer than the running
    /// app. Clears any stale `updateActionFailed` / `updateAssetMissing` flags
    /// from a prior session so a ready-to-install cached update is not masked by
    /// the curl fallback.
    public func rehydrateCachedUpdate(zipURL: URL, version: String) {
        updateZipURL = zipURL
        cachedUpdateVersion = version
        updateActionFailed = false
        updateAssetMissing = false
    }

    /// Moves to the "downloading" state: clears any cached zip URL / version and
    /// both fallback flags so the host shows a spinner while the new zip downloads.
    ///
    /// Do NOT call this from `clearDownloadState()`. The two methods share the same
    /// field-nil operations but carry different semantics: `setDownloadStarted()`
    /// signals that a spinner should appear; `clearDownloadState()` signals that
    /// stale zip state should be cleared without starting a spinner. The explicit
    /// override of `clearDownloadState()` in `RunnerState+AppUpdater.swift`
    /// duplicates these field assignments intentionally to preserve that distinction.
    public func setDownloadStarted() {
        updateZipURL = nil
        cachedUpdateVersion = nil
        updateActionFailed = false
        updateAssetMissing = false
    }

    /// Records a completed, integrity-verified download. The zip is cached at
    /// `zipURL` for `version`; clears the failure flag so the install
    /// affordance is shown.
    public func setDownloadComplete(zipURL: URL, version: String) {
        updateZipURL = zipURL
        cachedUpdateVersion = version
        updateActionFailed = false
    }

    /// Flags a failed download or install attempt so the curl-install fallback
    /// is shown. Also clears `updateAssetMissing` to avoid a simultaneous
    /// dual-failure state: if a prior session left `updateAssetMissing = true`
    /// and the current session fails a download, both flags would otherwise be
    /// `true` simultaneously.
    public func setUpdateFailed() {
        updateActionFailed = true
        updateAssetMissing = false
    }

    /// Flags that the discovered release carries no matching asset, so the
    /// curl-install fallback is shown. Also clears `updateActionFailed` to
    /// avoid a simultaneous dual-failure state: if a prior session left
    /// `updateActionFailed = true` and the current release has no asset,
    /// both flags would otherwise be `true` simultaneously.
    public func setAssetMissing() {
        updateAssetMissing = true
        updateActionFailed = false
    }

    /// `true` when the latest release exists but its `RunBot.zip` asset is absent.
    ///
    /// Set via `setAssetMissing()` when `AppUpdater.handle(_:state:)` finds no
    /// matching asset; cleared by `setDownloadStarted()` (a fresh download began,
    /// so the asset is now present), `setUpdateFailed()` (a download/install
    /// failure supersedes the asset-missing signal), and
    /// `rehydrateCachedUpdate(zipURL:version:)` (a cached zip exists, which is
    /// mutually exclusive with a missing asset).
    /// When `true` the UI falls back to a **Download** button that surfaces the
    /// curl install command.
    public internal(set) var updateAssetMissing: Bool = false

    /// `true` when a download **or** an install attempt has failed.
    ///
    /// The curl fallback is shown whenever `updateAssetMissing || updateActionFailed`.
    public internal(set) var updateActionFailed: Bool = false
}
