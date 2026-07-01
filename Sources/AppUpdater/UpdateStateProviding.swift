// UpdateStateProviding.swift
// AppUpdater
import Foundation

// MARK: - UpdateStateProviding

/// The host-app state model that `AppUpdater` drives while an update is
/// discovered, downloaded, and installed.
///
/// `AppUpdater` owns none of the UI state itself — it mutates a conforming
/// object supplied by the host app (typically an `@Observable @MainActor`
/// view model). The host observes that object to render its own update UI.
///
/// ## Why the whole protocol is `@MainActor`
///
/// The conforming type is expected to be observed by SwiftUI/AppKit, both of
/// which require main-thread access. Annotating the entire protocol (not just
/// individual requirements) is required for Swift 6 strict concurrency: it
/// makes every requirement main-actor isolated so `AppUpdater` (also
/// `@MainActor`) can call them synchronously without cross-actor hops, and it
/// lets conforming `@MainActor` classes satisfy the protocol without extra
/// `nonisolated` juggling.
///
/// ## Why read-only properties + explicit mutation methods
///
/// The properties are `{ get }` only and all state changes go through named
/// methods. This prevents TOCTOU-shaped misuse: a caller cannot set
/// `updateZipURL` without also setting `cachedUpdateVersion`, because there is
/// no setter — the paired write is encapsulated in `setDownloadComplete`.
/// Each method names an intent (download started / completed / failed) rather
/// than exposing raw fields, keeping every write site auditable.
///
/// `isDownloading` is intentionally NOT part of this protocol. Whether a
/// spinner is shown is a host-app UI detail; `AppUpdater` tracks in-flight
/// downloads with its own instance flag. The host only needs the mutation
/// hooks below to render a correct UI.
///
/// ## Why the protocol also refines `Sendable`
///
/// `AppUpdater.scheduleBackgroundCheck` captures the host-state existential in an
/// escaping `NSBackgroundActivityScheduler` closure that runs on a background
/// GCD queue. Refining `Sendable` makes `any UpdateStateProviding` safe to carry
/// across that boundary. This costs conformers nothing: every conformer is a
/// reference type isolated to `@MainActor` (the whole protocol is), and
/// global-actor-isolated classes are implicitly `Sendable`.
@MainActor
public protocol UpdateStateProviding: AnyObject, Sendable {

    /// Local file URL of the cached, verified update zip, or `nil` while no
    /// download is ready (in progress, not started, or failed).
    var updateZipURL: URL? { get }

    /// Version string of the cached update zip (e.g. `"v0.8.0"`), or `nil`
    /// when nothing is cached.
    var cachedUpdateVersion: String? { get }

    /// `true` when a download **or** install attempt failed. The host shows its
    /// curl-install fallback whenever this is `true`.
    var updateActionFailed: Bool { get }

    /// `true` when the discovered release exists but carries no matching asset
    /// to download. Tracked separately from `updateActionFailed` so the host can
    /// distinguish "release published without a binary" from "download/install
    /// failed" — both drive the same curl-install fallback today, but the
    /// distinct signal lets the host surface a more precise reason later.
    var updateAssetMissing: Bool { get }

    /// Records the version label of an available update (or clears it with
    /// `nil`). Called on every `.updateAvailable` result and to clear a stale
    /// row when the latest release is no longer newer.
    func setAvailableUpdate(_ version: String?)

    /// Signals that a fresh background download has begun. Implementations
    /// should move to a "downloading" state: clear any cached zip URL / version
    /// and clear both `updateActionFailed` and `updateAssetMissing` so a spinner
    /// is shown.
    func setDownloadStarted()

    /// Clears stale cached-download state without signalling that a new download
    /// is starting.
    ///
    /// Called when a post-install recovery path needs to reset `updateZipURL`
    /// and `cachedUpdateVersion` (which are now invalid — the zip was deleted as
    /// part of the install) without implying a download is about to begin.
    ///
    /// The default implementation calls `setDownloadStarted()` because the
    /// underlying field writes are identical. **Conformers that give
    /// `setDownloadStarted()` visible download-UI side-effects (e.g. showing a
    /// spinner) must override this method** to perform only the field clears,
    /// so the spinner is not shown during a post-install failure recovery.
    func clearDownloadState()

    /// Signals that a download completed and was integrity-verified. The zip is
    /// now cached at `zipURL` for `version`; the host should surface its
    /// install affordance.
    func setDownloadComplete(zipURL: URL, version: String)

    /// Signals that a download or install attempt failed. Implementations
    /// should set `updateActionFailed` and clear `updateAssetMissing` so the
    /// curl-install fallback shows and the prior asset-missing signal is not
    /// left stale from a previous session.
    func setUpdateFailed()

    /// Signals that the discovered release carries no matching downloadable
    /// asset. Implementations should set `updateAssetMissing` and clear
    /// `updateActionFailed` so the curl-install fallback shows. Distinct from
    /// `setUpdateFailed()`: nothing was attempted and failed — there was simply
    /// nothing to download.
    ///
    /// Implementations must clear `updateActionFailed` to avoid a simultaneous
    /// dual-failure state: if a prior session left `updateActionFailed = true`
    /// and the current release has no asset, both flags would otherwise be
    /// `true` at the same time — a state the protocol does not define.
    func setAssetMissing()

    /// Rehydrates cached download state on launch: the zip at `zipURL` for
    /// `version` was previously downloaded and still exists on disk.
    /// Implementations should set `updateZipURL`/`cachedUpdateVersion` and
    /// clear any stale `updateActionFailed` / `updateAssetMissing` flags from a
    /// prior session.
    func rehydrateCachedUpdate(zipURL: URL, version: String)
}

// MARK: - Default implementations

/// Default implementations for optional `UpdateStateProviding` requirements.
/// Conformers may override any of these to customise behaviour.
public extension UpdateStateProviding {

    /// Default implementation: delegates to `setDownloadStarted()` because the
    /// field writes are identical. Override if `setDownloadStarted()` has
    /// download-UI side-effects (e.g. a spinner) that must not fire here.
    func clearDownloadState() {
        setDownloadStarted()
    }
}
