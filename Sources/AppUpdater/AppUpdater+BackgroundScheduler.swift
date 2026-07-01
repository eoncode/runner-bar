// AppUpdater+BackgroundScheduler.swift
// AppUpdater

// AppKit is unavailable in the SPM headless test runner — this guard is
// required for `swift test` even though the package is macOS(.v26)-only.
#if canImport(AppKit)
import AppKit
#endif
import Foundation

// MARK: - Background scheduler

/// Background-scheduling logic for ``AppUpdater``.
///
/// The scheduler is guarded by `#if canImport(AppKit)` because
/// `NSBackgroundActivityScheduler` lives in AppKit. On platforms without AppKit
/// these entry points compile to no-ops so the library still builds.
extension AppUpdater {

    /// Registers an `NSBackgroundActivityScheduler` that fires a full update
    /// check every `AppUpdaterDefaults.checkInterval` seconds.
    ///
    /// Call once from the host's `AppDelegate` after the startup sequence
    /// completes. The scheduler is retained by `activity` so it is not
    /// deallocated before it fires (`NSBackgroundActivityScheduler` is not
    /// system-owned after `schedule { }` — unlike `Timer`, releasing it silently
    /// stops the check). It runs on a background queue and bridges back to
    /// `MainActor` for any host-state mutations.
    ///
    /// ## Retain cycle and teardown
    ///
    /// `self.activity` retains the `NSBackgroundActivityScheduler`, which retains
    /// the `schedule` closure, which captures `updater` (a strong reference to
    /// `self`). This forms an intentional retain cycle that keeps the scheduler
    /// alive for the process lifetime — releasing `AppUpdater` early would
    /// silently stop update checks.
    ///
    /// As a consequence, `deinit`'s `activity?.invalidate()` call is unreachable
    /// via the normal ARC path. **`cancelBackgroundCheck()` is the only correct
    /// teardown path.** Callers that do not use `AppUpdater` as a process-lifetime
    /// singleton must call `cancelBackgroundCheck()` explicitly before releasing
    /// their reference, or the scheduler will continue firing until the process
    /// exits.
    ///
    /// - Parameter state: The host update-state object to update.
    @MainActor
    public func scheduleBackgroundCheck(state: any UpdateStateProviding) { // skipcq: SW-R1002 — reviewed; complexity acceptable for this scheduler setup
        #if canImport(AppKit)
        let scheduler = NSBackgroundActivityScheduler(identifier: schedulerIdentifier)
        scheduler.repeats = true
        scheduler.interval = AppUpdaterDefaults.checkInterval
        // Allow the system up to 20 % of the interval as tolerance so it can
        // coalesce with other background work and save power.
        scheduler.tolerance = AppUpdaterDefaults.checkInterval * 0.2
        scheduler.qualityOfService = .background

        // `NSBackgroundActivityScheduler` is not `Sendable`. Capture a
        // `nonisolated(unsafe) let` copy before the closure so the capture is on
        // a Sendable-annotated binding, silencing the Swift 6
        // SendableClosureCaptures diagnostic (Pillar 6). Reading
        // `scheduler.shouldDefer` via a `let` copy is safe — AppKit guarantees
        // this callback fires on the same background serial queue that owns the
        // scheduler.
        nonisolated(unsafe) let schedulerRef = scheduler
        // Capture the values the check needs so the closure holds no reference
        // to `self` beyond these `Sendable`/in-actor captures. `AppUpdater` is a
        // `@MainActor final class` and thus implicitly `Sendable`, so no
        // `nonisolated(unsafe)` is needed on this binding.
        let updater = self
        scheduler.schedule { completion in
            // Honour the system's power-saving signal. `shouldDefer` returns true
            // when macOS is asking background tasks to pause (low battery, high
            // CPU). Calling `.deferred` tells the scheduler to retry at the next
            // interval rather than proceeding now.
            guard schedulerRef.shouldDefer == false else {
                completion(.deferred)
                return
            }
            // Tell the scheduler this invocation is done *before* spawning the
            // async work. `NSBackgroundActivityScheduler` mandates that
            // `completion` is called on the same GCD serial queue it dispatched
            // the closure on. Calling it from inside a `Task { }` would invoke it
            // on the Swift concurrency cooperative pool — an API contract
            // violation. This is safe: the scheduler only needs to know when
            // *this slot* is finished, not when the update check/download
            // completes. The Task below is fire-and-forget from the scheduler's
            // perspective.
            completion(.finished)

            // This unstructured Task hops to the main actor to read the host's
            // beta preference and drive host state. `betaChannelProvider` is
            // `@MainActor`, so the hop is required and correct.
            Task { @MainActor in
                let beta = updater.betaChannelProvider()
                switch await updater.checkForUpdate(betaChannel: beta) {
                case .updateAvailable(let release):
                    // Fire-and-forget handle() call. `setAvailableUpdate` is
                    // called inside handle() itself. `isDownloading` (in handle())
                    // prevents a second concurrent download if the scheduler fires
                    // again before this completes.
                    await updater.handle(release, state: state)

                case .upToDate:
                    // The latest release is no longer newer than the running
                    // version — either the update was installed, or the release
                    // was retracted. Clear the stale update row unconditionally.
                    state.setAvailableUpdate(nil)

                case .failed:
                    // A transient failure (network blip, rate-limit) must NOT
                    // clear a downloaded, ready-to-install update. Only clear if
                    // there is no cached zip on disk — meaning the row was shown
                    // from a check result alone and the zip was never downloaded
                    // (or was evicted by the OS under storage pressure).
                    let zipPath = updater.defaults.string(forKey: updater.keys.cachedUpdateZipPath)
                    let zipExists = zipPath.map { path in
                        FileManager.default.fileExists(atPath: path)
                    } ?? false
                    if !zipExists {
                        state.setAvailableUpdate(nil)
                    }
                }
            }
        }

        // Invalidate any previous scheduler before replacing it — Apple's API
        // requires invalidate() before release, and a second call (e.g. in tests)
        // must not drop the old scheduler without cleaning up its GCD state.
        activity?.invalidate()
        activity = scheduler
        #endif
    }

    // MARK: - Teardown

    /// Stops and invalidates the background update-check scheduler.
    ///
    /// `NSBackgroundActivityScheduler.invalidate()` is the documented shutdown
    /// API — without it a repeating scheduler fires until the process exits.
    /// After invalidation the `activity` property is nilled so a subsequent
    /// `scheduleBackgroundCheck` can install a fresh scheduler safely.
    ///
    /// This is the **only correct teardown path** for the scheduler. Because
    /// `scheduleBackgroundCheck` forms an intentional retain cycle
    /// (`self → activity → closure → self`), `deinit` is not reachable via
    /// ARC — callers must invoke this method explicitly when they no longer
    /// need background update checks.
    @MainActor
    public func cancelBackgroundCheck() {
        // AppKit is unavailable in the SPM headless test runner — this guard is
        // required for `swift test` even though the package is macOS(.v26)-only.
        #if canImport(AppKit)
        activity?.invalidate()
        activity = nil
        #endif
    }
}
