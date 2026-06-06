# 📁 File Hierarchy

A short description of every source file in the project.

---

```
runner-bar/
├── Package.swift                            — SPM manifest; defines RunnerBar + RunnerBarCore targets and their dependencies
├── project.yml                              — XcodeGen project definition
├── build.sh                                 — local build helper script
├── deploy.sh                                — deployment/release helper script
├── install.sh                               — runner installation helper script
├── README.md                                — project overview, screenshots, setup instructions
├── GRAVEYARD.md                             — archive of removed/deprecated code snippets
├── .swiftlint.yml                           — SwiftLint rule configuration
├── .periphery.yml                           — Periphery dead-code scanner configuration
│
├── docs/
│   └── FILE_HIERARCHY.md                    — this file; annotated map of the codebase
│
├── Sources/
│   │
│   ├── RunnerBarCore/                       (pure-logic target — no UI dependencies)
│   │   │
│   │   ├── GitHub/
│   │   │   ├── GitHubConstants.swift      — shared GitHub API base URLs and endpoint path constants
│   │   │   └── GitHubTransportShim.swift  — thin shim that routes requests through the active transport; holds the global ghRawTransport reference and a serial lock to guard replacement
│   │   │
│   │   ├── Runner/
│   │   │   ├── ActiveJob.swift            — model for a currently-running workflow job (name, status, started-at, URL)
│   │   │   ├── AggregateStatus.swift      — derives a single roll-up status from a collection of runner statuses
│   │   │   ├── JobStatus.swift            — enum of all possible GitHub Actions job states (queued, in_progress, completed, etc.)
│   │   │   ├── PollResultBuilder.swift    — assembles a PollResults value from raw API responses; handles vanished-job detection and failure-hook guard
│   │   │   ├── PollResults.swift          — value type carrying the full result of one poll cycle (runners + aggregate status)
│   │   │   ├── Runner.swift               — core Runner value type (id, name, OS, status, active jobs)
│   │   │   ├── RunnerMetrics.swift        — lightweight CPU/memory snapshot attached to a runner
│   │   │   ├── RunnerModel.swift          — Codable DTO that maps the GitHub REST runner JSON payload
│   │   │   ├── RunnerStatus.swift         — enum of runner lifecycle states (idle, active, offline, unknown)
│   │   │   ├── RunnerStatusEnricher.swift — merges live job data into a runner to produce an enriched status
│   │   │   ├── WorkflowActionGroup.swift  — groups related workflow runs under a single repo/branch key; exposes derived display props and elapsed time
│   │   │   └── WorkflowActionGroupFetch.swift — fetches and maps jobs for a WorkflowActionGroup from the GitHub API
│   │   │
│   │   ├── Scope/
│   │   │   ├── ScopeEntry.swift           — immutable value representing one monitored scope (org, repo, or user) with its enabled flag
│   │   │   └── ScopePreferencesStore.swift — reads and writes the list of ScopeEntry values to UserDefaults
│   │   │
│   │   ├── Services/
│   │   │   ├── LogFetcher.swift           — downloads raw step-log text for a given job URL
│   │   │   └── ProcessRunner.swift        — runs a shell command in a subprocess, captures stdout/stderr, merges stderr to /dev/null when not needed
│   │   │
│   │   └── Utilities/
│   │       ├── Logger.swift               — app-wide OSLog logger constants (one per subsystem category)
│   │       └── SystemStats.swift          — reads live CPU and disk usage via host_statistics / statvfs
│   │
│   └── RunnerBar/                           (UI target — AppKit + SwiftUI, macOS menu-bar app)
│       │
│       ├── main.swift                     — entry point; calls NSApplicationMain to launch the AppKit run loop
│       ├── Exports.swift                  — re-exports RunnerBarCore so UI code needs only one import
│       │
│       ├── App/
│       │   ├── AppDelegate.swift          — NSApplicationDelegate; owns lifecycle, sets up popover, triggers teardown
│       │   ├── AppDelegate+Navigation.swift — navigation helpers on AppDelegate (push/pop views, stepLog call-site)
│       │   ├── AppDelegate+PanelSetup.swift — configures the NSPopover and subscribes to close/open notifications
│       │   ├── AppDelegate+StatusItem.swift — creates the NSStatusItem and manages its menu-bar icon with triple-fallback
│       │   ├── NavState.swift             — observable navigation stack (history array, stepLog labels)
│       │   ├── PanelSheetState.swift      — tracks which sheet (if any) is currently presented in the panel
│       │   └── PanelVisibilityState.swift — publishes whether the popover panel is currently visible
│       │
│       ├── DesignSystem/
│       │   ├── DesignTokens.swift         — colour, spacing, and typography constants; adaptive() helper for light/dark; includes legacy shim
│       │   ├── PanelViewModifiers.swift   — reusable SwiftUI ViewModifiers (glass button style, panel-level padding, etc.)
│       │   └── RemovalAlertModifier.swift — ViewModifier that presents the runner-removal confirmation alert
│       │
│       ├── GitHub/
│       │   ├── Auth.swift                 — GitHub OAuth token cache; reads from Keychain
│       │   ├── GitHub.swift               — top-level GitHub API facade (fetch step log, raw URL session wrapper)
│       │   ├── GitHubURLSessionTransport.swift — URLSession-based REST transport; handles 401 sentinel, rate-limit atomicity, per-iteration token re-fetch
│       │   ├── GitHubCLITransport.swift   — former gh CLI transport (replaced by URLSession; kept for reference)
│       │   ├── Keychain.swift             — thin Keychain wrapper for storing/retrieving the OAuth token
│       │   ├── OAuthService.swift         — drives the GitHub OAuth Device Flow (sign-in URL, code exchange, CSRF check, callback handling)
│       │   ├── Scope.swift                — enum with .repo(owner:name:) and .org(_:) cases; parses raw scope strings and produces the correct GitHub REST API path prefix
│       │   └── Secrets.swift              — holds the GitHub App client-id and client-secret constants
│       │
│       ├── Models/
│       │   ├── RunnerEditCommit.swift     — immutable snapshot of runner edits ready to be committed to the API
│       │   └── RunnerEditDraft.swift      — mutable draft state for in-progress runner edits in the UI
│       │
│       ├── Panel/
│       │   ├── KeyablePanel.swift         — NSPanel subclass that accepts key events so the popover can receive keyboard input
│       │   └── PanelChrome.swift          — applies window-level chrome (vibrancy, corner radius) to the panel
│       │
│       ├── Preferences/
│       │   ├── AppPreferencesStore.swift  — registers and persists app-level user preferences (launch-at-login, notification settings, etc.)
│       │   └── NotificationPreferences.swift — model + persistence for per-event notification opt-in preferences
│       │
│       ├── Runner/
│       │   ├── LocalRunnerStore.swift     — @MainActor observable store of locally-registered runners; drives refresh and optimistic restore
│       │   ├── RunnerLifecycleService.swift — start/stop/remove lifecycle operations for a runner
│       │   ├── RunnerPollState.swift      — tracks the current polling phase and surfaces main.sync deadlock warnings
│       │   ├── RunnerStatusEnricher.swift — UI-layer tombstone; delegates to the Core enricher
│       │   ├── RunnerStore.swift          — observable store that owns the authoritative list of Runner values for the UI
│       │   ├── RunnerViewModel.swift      — @MainActor view-model bridging RunnerStore to SwiftUI; DI seam for testing
│       │   └── WorkflowActionGroupFetch.swift — UI-layer tombstone; re-exports Core fetch
│       │
│       ├── Scope/
│       │   ├── ScopeDetailView.swift      — SwiftUI view showing details and controls for a single scope entry
│       │   ├── ScopeEntry.swift           — UI-layer display wrapper around the Core ScopeEntry model
│       │   └── ScopeStore.swift           — @MainActor store that loads, persists, and mutates the list of monitored scopes
│       │
│       ├── Services/
│       │   ├── FailureHookRunner.swift    — runs the user-configured failure-hook shell command when a job fails; builds log-tail content
│       │   ├── LogFetcher.swift           — UI-layer thin wrapper around Core LogFetcher, adding MainActor dispatch
│       │   ├── LoginItem.swift            — registers/unregisters the app as a login item via SMAppService
│       │   ├── ProcessRunner.swift        — UI-layer tombstone; delegates to Core ProcessRunner
│       │   └── TerminalLauncher.swift     — opens a Terminal.app window and runs a given shell command in it
│       │
│       └── Views/
│           ├── Components/
│           │   ├── DonutStatusView.swift      — circular donut chart showing aggregate runner status at a glance
│           │   ├── SparklineView.swift        — mini sparkline graph of recent CPU or metric history for a runner
│           │   ├── SystemStatsView.swift      — displays live CPU and disk stats in the panel header
│           │   ├── SystemStatsViewModel.swift — samples CPU/disk periodically and publishes values to SystemStatsView
│           │   └── WorkflowContextMenuModifier.swift — adds a right-click context menu to workflow rows (copy URL, open in browser, etc.)
│           ├── Main/
│           │   ├── InlineJobRowsView.swift    — renders the inline expandable job-step rows inside a runner row
│           │   ├── PanelContainerView.swift   — top-level NSViewRepresentable that hosts the SwiftUI panel inside the NSPopover
│           │   ├── PanelMainView.swift        — root SwiftUI view of the popover panel; owns polling start and rate-limit banner
│           │   ├── PanelMainView+Subviews.swift — subview decomposition of PanelMainView (row containers, branch/tag pills, etc.)
│           │   └── WorkflowProgressExtensions.swift — SwiftUI extensions for mapping workflow status to progress-indicator state
│           ├── Settings/
│           │   ├── AddRunnerSheet.swift       — sheet for registering a new self-hosted runner (token fetch, timeout, keyWindow handling)
│           │   ├── AddScopeSheet.swift        — sheet for adding a new monitored scope (org/repo/user picker, manual entry)
│           │   ├── FailureHookCommandSheet.swift — sheet for editing the failure-hook shell command and inserting variables
│           │   ├── RunnerDetailPopover.swift  — popover showing runner metadata and a copy-to-pasteboard token action
│           │   └── SettingsView.swift         — main Settings tab view (login, notifications, scopes, runners, failure hook)
│           ├── Sheets/
│           │   ├── BranchSelectorSheet.swift  — sheet for picking a branch filter for a runner scope
│           │   └── RepoSelectorSheet.swift    — sheet for selecting a repository within the current scope
│           └── StepLog/
│               ├── LogCopyButton.swift        — button that copies the current step log to the clipboard with visual feedback
│               └── StepLogView.swift          — full-screen log viewer for a workflow step; fetches, parses, and displays raw log text
│
└── Tests/
    ├── RunnerBarCoreTests/
    │   └── RunnerBarCoreTests.swift         — unit tests for RunnerBarCore models and logic
    └── RunnerBarUITests/
        └── (UI test files — contents TBD)
```
