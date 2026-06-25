// LocalRunnerStore.swift
// RunnerBarCore
import Foundation

// MARK: - LocalRunnerStore

/// Swift 6 actor that owns the list of locally-installed GitHub Actions runner agents.
/// Hydrates from `installPath/.runner` JSON via `RunnerModelParser`,
/// marks live services via launchctl, then enriches with GitHub API data
/// (status, busy, labels, group).
///
/// **Concurrency model**
/// - The actor runs on its own executor (background thread).
/// - After every refresh cycle, results are pushed to the injected `RunnerViewModelProtocol`
///   conformer on the main actor via `await MainActor.run { }`. SwiftUI's `@Observable` machinery
///   picks up the mutation automatically.
/// - `isLocalScanning` is also pushed to the conformer so views can observe it
///   without holding a direct reference to the actor.
/// - Index persistence is delegated to `LocalRunnerIndex`.
/// - JSON parsing is delegated to `runnerModelFromIndex(name:installPath:)` in `RunnerModelParser`.
public actor LocalRunnerStore {
    // MARK: - Shared instance

    /// Backing storage. Set once at startup by `configure(viewModel:)` before any view
    /// is mounted. `@MainActor` ensures the compiler enforces single-actor write discipline
    /// without relying on `nonisolated(unsafe)` — any read from a non-`@MainActor` context
    /// is a compile-time error rather than a silent data race.
    @MainActor public private(set) static var sharedInstance: LocalRunnerStore?

    /// The app-wide shared instance. Must be called on the main actor.
    ///
    /// ⚠️ Must not be accessed before `configure(viewModel:)` is called from
    /// `AppDelegate+PanelSetup.applicationDidFinishLaunching`. Accessing it earlier
    /// produces a `fatalError` with a diagnostic message.
    @MainActor
    public static var shared: LocalRunnerStore {
        guard let instance = sharedInstance else {
            fatalError(
                "LocalRunnerStore.shared accessed before configure(viewModel:) was called. "
                    + "Call LocalRunnerStore.configure(viewModel: appDelegate.runnerState) in "
                    + "applicationDidFinishLaunching before using this accessor."
            )
        }
        return instance
    }

    /// Creates the shared instance wired to `viewModel` and stores it.
    ///
    /// Must be called **once**, on the main actor, before any view is mounted or any
    /// `refresh()` call is made. Safe to call multiple times in tests (each call
    /// replaces the previous instance and shuts it down).
    ///
    /// ⚠️ **Test suites that call this method must be marked `@Suite(.serialized)`.**
    /// `sharedInstance` is `@MainActor`; two test cases calling `configure(viewModel:)`
    /// concurrently will race unless serialised. The compiler enforces `@MainActor`
    /// access to `sharedInstance`, so any off-actor write is a compile-time error.
    @MainActor
    public static func configure(viewModel: any RunnerViewModelProtocol) {
        // Shut down the previous instance before replacing it so its in-flight
        // Tasks are cancelled and cannot deliver stale snapshots into the new viewModel.
        //
        // `shutdown()` is isolated to the LocalRunnerStore actor (a different actor from
        // @MainActor), so it cannot be called synchronously here in Swift 6. A detached
        // Task is safe: shutdown() only cancels refreshTask, which is fire-and-forget by
        // design. The new sharedInstance assignment below happens on the main actor immediately,
        // so any snapshot the old actor pushes after this point targets the old viewModel
        // reference it already holds — it cannot corrupt the new instance.
        //
        // ⚠️ This isolation guarantee requires the old and new viewModel to be *different*
        // objects. Tests must pass a fresh RunnerState (or mock) on each configure call;
        // reusing the same instance means the old actor's in-flight pushes can still land
        // in the new instance's shared push target.
        if let previous = sharedInstance {
            Task { await previous.shutdown() }
        }
        sharedInstance = LocalRunnerStore(viewModel: viewModel)
        log("LocalRunnerStore › configure — shared instance created, wired to viewModel=\(ObjectIdentifier(viewModel))")
    }

    // MARK: - Internal actor state

    /// The current list of locally-installed runners, sorted by name.
    /// Private: all external reads go through `viewModel.localRunners` (pushed via MainActor.run).
    /// Widening to internal is unnecessary — the `localRunners` closure in AppDelegate+PanelSetup
    /// reads `runnerState.localRunners`, not this property directly.
    private var runners: [RunnerModel] = []

    /// `true` while a refresh cycle is in flight; prevents concurrent refreshes.
    private var isScanning: Bool = false

    /// Task driving the fire-and-forget refresh loop; cancelled by `shutdown()`.
    private var refreshTask: Task<Void, Never>?

    // MARK: - Injected dependencies

    /// The view model this actor pushes UI state into.
    private let viewModel: any RunnerViewModelProtocol

    /// Persistence layer for the runner name → install path mapping.
    private let index = LocalRunnerIndex()

    /// Enricher that applies GitHub API data (status, busy, labels, group) to
    /// locally-discovered runners. Injected at init so unit tests can supply a stub
    /// without going through the live singleton (Phase 6b, #1326).
    private let enricher: any RunnerStatusEnricherProtocol

    // MARK: - Init

    /// Designated init for dependency injection.
    ///
    /// - Parameters:
    ///   - viewModel: The view model this actor pushes UI state into.
    ///   - enricher: Provides GitHub API enrichment for locally-discovered runners.
    ///     Pass `RunnerStatusEnricher()` in production; inject a test double in unit tests.
    ///     The `shared` singleton has been removed (#1539 item 22) — callers must
    ///     construct an explicit instance.
    public init(
        viewModel: any RunnerViewModelProtocol,
        enricher: any RunnerStatusEnricherProtocol = RunnerStatusEnricher()
    ) {
        self.viewModel = viewModel
        self.enricher = enricher
        log("LocalRunnerStore › init — runnerIndex.count=\(index.runnerIndex.count), runners=[] (call refresh() to hydrate)")
    }

    // MARK: - Shutdown

    /// Cancels all in-flight Tasks owned by this instance.
    ///
    /// Called by `configure(viewModel:)` before replacing `sharedInstance` so that the
    /// previous actor's background work does not push stale snapshots into the
    /// incoming `viewModel`.
    public func shutdown() {
        refreshTask?.cancel()
        refreshTask = nil
        log("LocalRunnerStore › shutdown — refreshTask cancelled")
    }

    // MARK: - Index helpers

    /// Adds or updates the index entry for `name`, mapping it to `installPath`, then persists.
    ///
    /// - Parameters:
    ///   - name: The runner's display name.
    ///   - installPath: The absolute path to the runner's installation directory.
    func register(name: String, installPath: String) {
        index.register(name: name, installPath: installPath)
    }

    /// Removes `name` from the persisted index.
    ///
    /// - Parameter name: The runner's display name to remove.
    func unregister(name: String) {
        index.unregister(name: name)
    }

    // MARK: - Convenience API (called by views via Task { await ... })

    /// Registers a new runner by name and install path.
    public func add(runnerName: String, installPath: String) {
        log("LocalRunnerStore › add — '\(runnerName)' at \(installPath)")
        register(name: runnerName, installPath: installPath)
    }

    /// Immediately reflects a start/stop action before the next refresh cycle.
    public func optimisticallySetRunning(_ runnerName: String, isRunning: Bool) async {
        log("LocalRunnerStore › optimisticallySetRunning '\(runnerName)' isRunning=\(isRunning)")
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else {
            log("LocalRunnerStore › ⚠️ optimisticallySetRunning — '\(runnerName)' not found in runners (count=\(runners.count))")
            return
        }
        runners[idx] = runners[idx].copying(isRunning: isRunning)
        await pushRunners()
    }

    /// Sets or clears the lifecycle warning badge for a runner.
    public func setLifecycleWarning(_ runnerName: String, warning: String?) async {
        log("LocalRunnerStore › setLifecycleWarning '\(runnerName)' warning=\(String(describing: warning))")
        guard let idx = runners.firstIndex(where: { $0.runnerName == runnerName }) else {
            log("LocalRunnerStore › ⚠️ setLifecycleWarning — '\(runnerName)' not found in runners (count=\(runners.count))")
            return
        }
        runners[idx] = runners[idx].copying(lifecycleWarning: warning)
        await pushRunners()
    }

    /// Immediately removes `runnerName` from the index and display list without waiting for a refresh.
    public func optimisticallyRemove(_ runnerName: String) async {
        log("LocalRunnerStore › optimisticallyRemove '\(runnerName)'")
        unregister(name: runnerName)
        let beforeCount = runners.count
        runners.removeAll { $0.runnerName == runnerName }
        log("LocalRunnerStore › optimisticallyRemove '\(runnerName)' — runners \(beforeCount)→\(runners.count)")
        await pushRunners()
    }

    /// Rolls back an `optimisticallyRemove` by re-registering the runner and restoring it.
    public func optimisticallyRestore(_ runner: RunnerModel) async {
        log("LocalRunnerStore › optimisticallyRestore '\(runner.runnerName)' installPath=\(String(describing: runner.installPath))")
        if let installPath = runner.installPath {
            register(name: runner.runnerName, installPath: installPath)
        } else {
            log("LocalRunnerStore › ⚠️ optimisticallyRestore — no installPath for '\(runner.runnerName)', index entry NOT restored")
        }
        if !runners.contains(where: { $0.runnerName == runner.runnerName }) {
            runners.append(runner)
            log("LocalRunnerStore › optimisticallyRestore — appended '\(runner.runnerName)', runners.count=\(runners.count)")
        } else {
            log("LocalRunnerStore › optimisticallyRestore — '\(runner.runnerName)' already present, skipped append")
        }
        await pushRunners()
    }

    // MARK: - Metrics write-back

    /// Applies a CPU/memory snapshot to the matching `RunnerModel` in place.
    ///
    /// Match priority (fixes org-runner metrics #1209 / #1192):
    ///   1. runner.apiId   == runnerId (GitHub REST API id — org runners use this)
    ///   2. runner.agentId == runnerId (local .runner JSON AgentId — repo runners use this)
    ///   3. runner.runnerName == name  (name-only last resort)
    public func applyMetrics(_ metrics: RunnerMetrics?, forRunnerId runnerId: Int?, name: String) async {
        #if DEBUG
        log("LocalRunnerStore › applyMetrics — called with runnerId=\(String(describing: runnerId)) name=\(name) metrics=\(String(describing: metrics))")
        // swiftlint:disable:next line_length
        log("LocalRunnerStore › applyMetrics — runners.count=\(runners.count) candidates=\(runners.map { "\($0.runnerName)(agentId=\(String(describing: $0.agentId)) apiId=\(String(describing: $0.apiId)))" })")
        #endif

        guard let idx = runners.firstIndex(where: { runner in
            if let rid = runnerId, let aid = runner.apiId, aid == rid {
                log("LocalRunnerStore › applyMetrics — MATCH via apiId=\(aid) for '\(runner.runnerName)'")
                return true
            }
            if let rid = runnerId, let aid = runner.agentId, aid == rid {
                log("LocalRunnerStore › applyMetrics — MATCH via agentId=\(aid) for '\(runner.runnerName)'")
                return true
            }
            if runner.runnerName == name {
                log("LocalRunnerStore › applyMetrics — MATCH via name='\(name)' for '\(runner.runnerName)'")
                return true
            }
            return false
        }) else {
            // swiftlint:disable:next line_length
            log("LocalRunnerStore › ⚠️ applyMetrics — NO MATCH for runnerId=\(String(describing: runnerId)) name=\(name). runners=\(runners.map { "\($0.runnerName)(agentId=\(String(describing: $0.agentId)) apiId=\(String(describing: $0.apiId)))" })")
            return
        }
        log("LocalRunnerStore › applyMetrics — writing metrics=\(String(describing: metrics)) to '\(runners[idx].runnerName)'")
        runners[idx] = runners[idx].copying(metrics: metrics)
        await pushRunners()
    }

    // MARK: - Refresh

    /// Fire-and-forget refresh. Spawns a Task and returns immediately.
    ///
    /// Use this from views and on-demand callers (e.g. SettingsView lifecycle actions)
    /// that do not need to wait for completion.
    ///
    /// At app startup, prefer `refreshAsync()` so that `RunnerStore.start()` is only
    /// called after `runners` is fully populated — ensuring cycle-1 `installPathMap`
    /// is never empty and metrics appear on first runner appearance.
    public func refresh() {
        log("LocalRunnerStore › refresh() — fire-and-forget wrapper")
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
        }
    }

    /// Awaitable refresh. Suspends until disk hydration + launchctl + GitHub enrichment
    /// completes, then returns.
    ///
    /// Use ONLY at app startup in `AppDelegate+PanelSetup` so that `RunnerStore.start()`
    /// is guaranteed to have a populated `runners` array before its first `fetch()` fires.
    public func refreshAsync() async {
        await performRefresh()
    }

    /// Shared body for both `refresh()` and `refreshAsync()`.
    /// Hydrates runners from disk, marks live launchctl services, then enriches via GitHub API.
    ///
    /// IMPORTANT: This is the ONLY way `runners` gets populated.
    /// `init()` only loads `runnerIndex` (name→path). `runners` stays `[]` until this runs.
    private func performRefresh() async {
        log("LocalRunnerStore › performRefresh() — isScanning=\(isScanning) runnerIndex.count=\(index.runnerIndex.count) runners.count=\(runners.count)")
        guard !isScanning else {
            log("LocalRunnerStore › performRefresh() — already scanning, skipping (isScanning=true)")
            return
        }
        isScanning = true
        await MainActor.run { [viewModel] in viewModel.isLocalScanning = true }
        let currentIndex = index.runnerIndex
        log("LocalRunnerStore › performRefresh() — starting with index=\(currentIndex.keys.sorted())")

        // 1. Hydrate from installPath/.runner JSON
        var hydrated: [RunnerModel] = currentIndex.compactMap { runnerModelFromIndex(name: $0.key, installPath: $0.value) }
        log("LocalRunnerStore › performRefresh() hydrated \(hydrated.count) runner(s) from disk (index had \(currentIndex.count) entries)")
        if hydrated.count != currentIndex.count {
            let hydratedNames = Set(hydrated.map { $0.runnerName })
            let missing = currentIndex.keys.filter { !hydratedNames.contains($0) }
            log("LocalRunnerStore › ⚠️ performRefresh() — \(currentIndex.count - hydrated.count) runner(s) failed to hydrate (missing .runner JSON): \(missing)")
        }

        // 2. Mark live services via launchctl.
        let liveLabels = await scanLiveServices()
        log("LocalRunnerStore › performRefresh() — launchctl liveLabels.count=\(liveLabels.count): \(liveLabels)")
        hydrated = hydrated.map { runner in
            let live = liveLabels.contains { $0.contains(runner.runnerName) }
            #if DEBUG
            log("LocalRunnerStore › performRefresh() — '\(runner.runnerName)' isRunning=\(live)")
            #endif
            return runner.copying(isRunning: live)
        }

        // 3. Enrich via GitHub API (concurrent scope fetches).
        // Uses the injected enricher — pass RunnerStatusEnricher() in production,
        // or a StubEnricher in unit tests (Phase 6b, #1326).
        log("LocalRunnerStore › performRefresh() — starting GitHub enrichment for \(hydrated.count) runner(s)")
        let enriched = await enricher.enrich(runners: hydrated)
        log("LocalRunnerStore › performRefresh() — GitHub enrichment complete, \(enriched.count) runner(s) enriched")
        #if DEBUG
        log("LocalRunnerStore › performRefresh() — enriched apiIds=\(enriched.map { "\($0.runnerName)(apiId=\(String(describing: $0.apiId)) agentId=\(String(describing: $0.agentId)))" })")
        #endif

        await applyRefreshResults(enriched)
    }

    /// Applies enriched runner data, preserves in-flight metrics, pushes to viewModel.
    ///
    /// Metrics preservation priority (fixes org-runner metrics #1209 / #1192):
    ///   1. runner.apiId  match (org runners: GitHub REST API id ≠ local agentId)
    ///   2. runner.agentId match (repo runners)
    ///   3. runner.runnerName match (last resort)
    ///
    /// `isLocalScanning` is reset to `false` via `await MainActor.run { }` directly
    /// (not via a fire-and-forget Task) so that a concurrent scan cannot set it back
    /// to `true` between `isScanning = false` and the main-actor push.
    private func applyRefreshResults(_ enriched: [RunnerModel]) async {
        log("LocalRunnerStore › applyRefreshResults — enriched.count=\(enriched.count), current runners.count=\(runners.count)")

        var metricsByApiId: [Int: RunnerMetrics] = [:]
        var metricsByAgentId: [Int: RunnerMetrics] = [:]
        var metricsByName: [String: RunnerMetrics] = [:]
        for runner in runners {
            guard runner.isBusy, let preservedMetrics = runner.metrics else { continue }
            if let id = runner.apiId { metricsByApiId[id] = preservedMetrics }  // Priority 1: GitHub REST API id
            if let id = runner.agentId { metricsByAgentId[id] = preservedMetrics }  // Priority 2: local AgentId
            metricsByName[runner.runnerName] = preservedMetrics  // Priority 3: name (last resort)
        }
        #if DEBUG
        log("LocalRunnerStore › applyRefreshResults — preserved metrics: byApiId=\(metricsByApiId.keys.sorted()) byAgentId=\(metricsByAgentId.keys.sorted()) byName=\(metricsByName.keys.sorted())")
        #endif

        let preserved: [RunnerModel] = enriched.map { runner in
            if let id = runner.apiId, let metrics = metricsByApiId[id] {
                #if DEBUG
                log("LocalRunnerStore › applyRefreshResults — preserved metrics for '\(runner.runnerName)' via apiId=\(id)")
                #endif
                return runner.copying(metrics: metrics)
            }
            if let id = runner.agentId, let metrics = metricsByAgentId[id] {
                #if DEBUG
                log("LocalRunnerStore › applyRefreshResults — preserved metrics for '\(runner.runnerName)' via agentId=\(id)")
                #endif
                return runner.copying(metrics: metrics)
            }
            if let metrics = metricsByName[runner.runnerName] {
                #if DEBUG
                log("LocalRunnerStore › applyRefreshResults — preserved metrics for '\(runner.runnerName)' via name")
                #endif
                return runner.copying(metrics: metrics)
            }
            #if DEBUG
            log("LocalRunnerStore › applyRefreshResults — no metrics to preserve for '\(runner.runnerName)'")
            #endif
            return runner
        }
        runners = preserved.sorted { $0.runnerName < $1.runnerName }
        isScanning = false
        log("LocalRunnerStore › applyRefreshResults — DONE. runners.count=\(runners.count) isScanning=false")
        // Await directly — not fire-and-forget — so isLocalScanning cannot be
        // reset to false by a stale Task after a second scan has already started.
        let snapshot = runners
        await MainActor.run { [viewModel] in
            viewModel.localRunners = snapshot
            viewModel.isLocalScanning = false
        }
    }

    // MARK: - Push helpers

    /// Pushes the current `runners` snapshot to `viewModel.localRunners` on the main actor.
    /// Called after every optimistic mutation so views update immediately.
    ///
    /// `async` + direct `await MainActor.run` (not a fire-and-forget Task) guarantees
    /// that two rapid mutations deliver their snapshots in actor-serialised order.
    /// A detached Task would allow a later mutation's push to arrive before an earlier
    /// one, silently reverting the UI (e.g. Stop → Remove race).
    private func pushRunners() async {
        let snapshot = runners
        await MainActor.run { [viewModel] in viewModel.localRunners = snapshot }
    }

    // MARK: - launchctl scan

    /// Path to `launchctl`, used to list live runner services.
    private static let launchctlURL = URL(fileURLWithPath: "/bin/launchctl") // NOSONAR

    /// Runs `launchctl list` and returns lines that contain `actions.runner`.
    private func scanLiveServices() async -> [String] {
        log("LocalRunnerStore › scanLiveServices — running launchctl list")
        let result = await ProcessRunner.runAsync(
            executableURL: Self.launchctlURL,
            arguments: ["list"],
            timeout: 5
        )
        guard let data = result.data,
              let output = String(data: data, encoding: .utf8) else {
            log("LocalRunnerStore › ⚠️ scanLiveServices — launchctl returned no data or non-UTF8 output")
            return []
        }
        let lines = output.components(separatedBy: "\n").filter { $0.contains("actions.runner") }
        log("LocalRunnerStore › scanLiveServices — found \(lines.count) live actions.runner service(s)")
        return lines
    }
}
