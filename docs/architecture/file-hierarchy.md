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
├── LICENSE                                  — project licence
├── sonar-project.properties                 — SonarCloud project configuration
├── .swiftlint.yml                           — SwiftLint rule configuration
├── .periphery.yml                           — Periphery dead-code scanner configuration
│
├── docs/
│   ├── architecture/
│   │   ├── AGENTS.md                        — AI agent usage guidelines for this codebase
│   │   ├── FILE_HIERARCHY.md                — this file; annotated map of the codebase
│   │   ├── UI-ARCHITECTURE.md               — UI layer architecture overview and component responsibilities
│   │   ├── project-principles.md            — core engineering principles and conventions for the project
│   │   └── reach-goal-principles.md         — aspirational / stretch principles guiding future architecture decisions
│   ├── design/
│   │   ├── brand-inspiration_developer-tools_2026-06-02.md — brand/design inspiration notes
│   │   ├── dark_light_mode_support.md       — notes on dark/light mode adaptive design
│   │   ├── liquid-glass.md                  — liquid-glass visual design exploration
│   │   ├── runnerbar_v34_light_glass.html   — HTML prototype of the v34 light glass UI
│   │   └── zap.svg                          — zap icon asset used in design explorations
│   ├── guides/
│   │   ├── DEPLOYMENT.md                    — release and deployment instructions
│   │   ├── DEVELOPMENT.md                   — local development setup and workflow
│   │   ├── UI_TESTING.md                    — UI testing approach and instructions
│   │   ├── commenting-standard.md           — code commenting conventions for the project
│   │   ├── dev-with-log-in-terminal.md      — how to run the app with live log output in Terminal
│   │   └── useful-commands.md               — handy shell commands for development tasks
│   ├── legal-and-security/
│   │   ├── GitHub-Permission-Rationale.md   — justification for requested GitHub OAuth scopes
│   │   └── PRIVACY.md                       — privacy policy and data-handling notes
│   └── ui/
│       ├── nspopoer-without-jump-issues.md  — fix notes for NSPopover repositioning jumps
│       ├── status-bar-app-position-warning.md — notes on status-bar icon positioning edge cases
│       └── status-bar-window.md             — status-bar window construction notes
│
├── Sources/
│   │
│   ├── RunnerBarCore/                       (pure-logic target — no UI dependencies)
│   │   │
│   │   ├── GitHub/
│   │   │   ├── GitHubConstants.swift        — shared GitHub API base URLs and endpoint path constants
│   │   │   ├── GitHubRateLimitHandler.swift  — actor-isolated rate-limit state machine; replaces old OSAllocatedUnfairLock approach
│   │   │   ├── GitHubRequestBuilder.swift   — constructs authenticated URLRequests for the GitHub REST API
│   │   │   ├── GitHubResponseDecoder.swift  — decodes and validates GitHub API JSON responses; surfaces typed errors
│   │   │   ├── GitHubTransportShim.swift    — thin shim that routes requests through the active transport; holds the global ghRawTransport reference and a serial lock to guard replacement
│   │   │   └── GitHubURLSessionTransport.swift — URLSession-based REST transport; handles 401 sentinel, rate-limit atomicity, per-iteration token re-fetch
│   │   │
│   │   ├── Runner/
│   │   │   ├── ActiveJob.swift              — model for a currently-running workflow job (name, status, started-at, URL)
│   │   │   ├── AggregateStatus.swift        — derives a single roll-up status from a collection of runner statuses
│   │   │   ├── CommitResult.swift           — outcome enum for a SaveRunnerEditsUseCase.execute call (success or failure with errors)
│   │   │   ├── JobStatus.swift              — enum of all possible GitHub Actions job states (queued, in_progress, completed, etc.)
│   │   │   ├── LocalRunnerIndex.swift       — UserDefaults-backed name → install-path index; pure persistence layer, easily unit-testable
│   │   │   ├── PollResultBuilder.swift      — assembles a PollResults value from raw API responses; handles vanished-job detection and failure-hook guard
│   │   │   ├── PollResults.swift            — value type carrying the full result of one poll cycle (runners + aggregate status)
│   │   │   ├── Runner.swift                 — core Runner value type (id, name, OS, status, active jobs)
│   │   │   ├── RunnerConfig.swift           — typed Codable representation of the .runner JSON config file written by the GitHub Actions runner agent
│   │   │   ├── RunnerConfigStore.swift      — reads and writes RunnerConfig to the .runner file in a runner's install directory
│   │   │   ├── RunnerConfigStoreProtocol.swift — abstraction over RunnerConfigStore enabling test doubles
│   │   │   ├── RunnerEditDraft.swift        — value-type buffer of all editable runner fields; initialised from live model + config files, mutated in-memory
│   │   │   ├── RunnerLabelsServiceProtocol.swift — abstraction over the patchRunnerLabels network call for dependency injection
│   │   │   ├── RunnerMetrics.swift          — lightweight CPU/memory snapshot attached to a runner
│   │   │   ├── RunnerModel.swift            — Codable DTO that maps the GitHub REST runner JSON payload
│   │   │   ├── RunnerModelParser.swift      — reads installPath/.runner JSON and builds a RunnerModel; handles UTF-8 BOM stripping
│   │   │   ├── RunnerProxyConfig.swift      — typed value representing proxy configuration stored in .proxy and .proxycredentials files
│   │   │   ├── RunnerProxyStoreProtocol.swift — abstraction over RunnerProxyStore enabling test doubles
│   │   │   ├── RunnerStatus.swift           — enum of runner lifecycle states (idle, active, offline, unknown)
│   │   │   ├── RunnerStatusEnricher.swift   — merges live job data into a runner to produce an enriched status
│   │   │   ├── RunnerStatusEnricherProtocol.swift — abstraction over runner-status enrichment introduced for LocalRunnerStore DI
│   │   │   ├── SaveRunnerEditsUseCase.swift — testable DI replacement for the commitRunnerEdit free function; executes the three-step commit transaction
│   │   │   ├── WorkflowActionGroup.swift    — groups related workflow runs under a single repo/branch key; exposes derived display props and elapsed time
│   │   │   └── WorkflowActionGroupFetch.swift — fetches and maps jobs for a WorkflowActionGroup from the GitHub API
│   │   │
│   │   ├── Scope/
│   │   │   ├── FailureHookRunnerDependencies.swift — ScopePreferencesStoreProtocol abstraction used by FailureHookRunnerUseCase to avoid hitting UserDefaults in tests
│   │   │   ├── GitHubScope.swift            — enum representing a GitHub monitoring scope (.repo or .org); parses raw scope strings and produces REST API path prefixes
│   │   │   ├── ScopeEntry.swift             — immutable value representing one monitored scope (org, repo, or user) with its enabled flag
│   │   │   └── ScopePreferencesStore.swift  — reads and writes the list of ScopeEntry values to UserDefaults
│   │   │
│   │   ├── Services/
│   │   │   ├── DefaultRunnerLabelsService.swift — live conformance of RunnerLabelsService; delegates to patchRunnerLabels in GitHubTransportShims; moved from RunnerBar in #1610
│   │   │   ├── LogFetcher.swift             — downloads raw step-log text for a given job URL
│   │   │   └── ProcessRunner.swift          — runs a shell command in a subprocess, captures stdout/stderr, merges stderr to /dev/null when not needed
│   │   │
│   │   └── Utilities/
│   │       ├── AnyJSON.swift                — type-erased Codable value that round-trips arbitrary JSON without JSONSerialization
│   │       ├── FormatElapsed.swift          — centralised mm:ss elapsed-time formatter shared by ActiveJob, JobStep, and WorkflowActionGroup+Progress
│   │       ├── GitHubURLHelpers.swift       — extracts owner/repo or orgName scope string from a GitHub HTML URL
│   │       ├── ISO8601DateParser.swift      — lightweight ISO 8601 date parsing helpers used across the core layer
│   │       ├── Logger.swift                 — app-wide OSLog logger constants (one per subsystem category)
│   │       └── SystemStats.swift            — reads live CPU and disk usage via host_statistics / statvfs
│   │
│   └── RunnerBar/                           (UI target — AppKit + SwiftUI, macOS menu-bar app)
│       │
│       ├── main.swift                       — entry point; calls NSApplicationMain to launch the AppKit run loop
│       ├── Exports.swift                    — re-exports RunnerBarCore so UI code needs only one import
│       │
│       ├── App/
│       │   ├── AppDelegate.swift            — NSApplicationDelegate; owns lifecycle, sets up popover, triggers teardown
│       │   ├── AppDelegate+Navigation.swift — navigation helpers on AppDelegate (push/pop views, stepLog call-site)
│       │   ├── AppDelegate+OAuthCallback.swift — handles the OAuth redirect callback and exchanges the code for a token
│       │   ├── AppDelegate+PanelSetup.swift — configures the NSPopover and subscribes to close/open notifications
│       │   ├── AppDelegate+Polling.swift    — wires up the poll loop start/stop on panel open/close events
│       │   ├── AppDelegate+StatusItem.swift — creates the NSStatusItem and manages its menu-bar icon with triple-fallback
│       │   ├── AppDelegate+StoreSetup.swift — initialises and wires observable stores on launch
│       │   ├── NavState.swift               — observable navigation stack (history array, stepLog labels)
│       │   ├── PanelSheetState.swift        — tracks which sheet (if any) is currently presented in the panel
│       │   ├── PanelVisibilityState.swift   — publishes whether the popover panel is currently visible
│       │   └── PopoverLifecycleCoordinator.swift — owns the four popover lifecycle concerns extracted from AppDelegate: panel-open flag, preserved-sheet-window flag, outside-click monitor, and popover delegate
│       │
│       ├── DesignSystem/
│       │   ├── DesignTokens.swift           — colour, spacing, and typography constants; adaptive() helper for light/dark; includes legacy shim
│       │   ├── PanelViewModifiers.swift     — reusable SwiftUI ViewModifiers (glass button style, panel-level padding, etc.)
│       │   └── RemovalAlertModifier.swift   — ViewModifier that presents the runner-removal confirmation alert
│       │
│       ├── GitHub/
│       │   ├── GitHubTokenCache.swift       — lock-protected in-memory cache for the resolved GitHub token; cleared after saving a new token to Keychain
│       │   ├── OAuthSecrets.swift           — holds the GitHub App client-id and client-secret constants
│       │   └── OAuthService.swift           — drives the GitHub OAuth Device Flow (sign-in URL, code exchange, CSRF check, callback handling)
│       │
│       ├── Preferences/
│       │   ├── AppPreferencesStore.swift    — registers and persists app-level user preferences (launch-at-login, notification settings, etc.)
│       │   └── NotificationPreferences.swift — model + persistence for per-event notification opt-in preferences
│       │
│       ├── Runner/
│       │   ├── CommitRunnerEdit.swift       — retained for git history only; logic moved to RunnerBarCore/Runner/CommitResult.swift and SaveRunnerEditsUseCase.swift
│       │   ├── LocalRunnerStore.swift       — @MainActor observable store of locally-registered runners; drives refresh and optimistic restore
│       │   ├── RunnerEditDraft.swift        — (UI shim) forwards to the Core RunnerEditDraft; retained for import compatibility
│       │   ├── RunnerLifecycleService.swift — start/stop/remove lifecycle operations for a runner
│       │   ├── RunnerProxyStore.swift       — reads and writes .proxy / .proxycredentials files for a runner's install directory
│       │   ├── RunnerStore+InstallPathMap.swift — extension mapping runner IDs to their local install paths
│       │   ├── RunnerStore+PollBridge.swift — extension bridging PollResultBuilder for the RunnerStore fetch() call sites
│       │   ├── RunnerStore+PollLoop.swift   — extension containing the async poll-loop driver on RunnerStore
│       │   └── RunnerStore.swift            — observable store that owns the authoritative list of Runner values for the UI
│       │
│       ├── Scope/
│       │   └── ScopeStore.swift             — @MainActor store that loads, persists, and mutates the list of monitored scopes
│       │
│       ├── Services/
│       │   ├── DefaultRunnerLabelsService.swift — retained for git history only; moved to RunnerBarCore/Services/ in #1610
│       │   ├── FailureHookRunner.swift      — runs the user-configured failure-hook shell command when a job fails; builds log-tail content
│       │   ├── FailureHookRunnerAdapters.swift — lightweight production adapters bridging static ScopePreferencesStore and TerminalLauncher singletons to FailureHookRunnerUseCase
│       │   ├── Keychain.swift               — Security.framework wrapper for storing and retrieving the GitHub OAuth token
│       │   ├── LoginItem.swift              — registers/unregisters the app as a login item via SMAppService
│       │   └── TerminalLauncher.swift       — opens a Terminal.app window and runs a given shell command in it
│       │
│       ├── UseCases/
│       │   └── FailureHookRunnerUseCase.swift — testable DI replacement for the FailureHookRunner static enum; fires per-scope failure-hook command when a WorkflowActionGroup fails
│       │
│       ├── Utilities/
│       │   └── WindowGrabber.swift          — utility that locates the key NSWindow for sheet presentation
│       │
│       └── Views/
│           ├── Components/
│           │   ├── DonutStatusView.swift    — circular donut chart showing aggregate runner status at a glance
│           │   ├── RingBuffer.swift         — fixed-capacity circular buffer; values property returns elements oldest-first
│           │   ├── SparklineView.swift      — mini sparkline graph of recent CPU or metric history for a runner
│           │   ├── SystemStatsView.swift    — displays live CPU and disk stats in the panel header
│           │   ├── SystemStatsViewModel.swift — samples CPU/disk periodically and publishes values to SystemStatsView
│           │   └── WorkflowContextMenuModifier.swift — adds a right-click context menu to workflow rows (copy URL, open in browser, etc.)
│           ├── Main/
│           │   ├── ActionRowView.swift      — renders a single workflow-action row with status icon and elapsed time
│           │   ├── InlineJobRowsView.swift  — renders the inline expandable job-step rows inside a runner row
│           │   ├── PanelContainerView.swift — top-level NSViewRepresentable that hosts the SwiftUI panel inside the NSPopover
│           │   ├── PanelHeaderView.swift    — header bar of the panel showing app title, system stats, and settings button
│           │   ├── PanelMainView.swift      — root SwiftUI view of the popover panel; owns polling start and rate-limit banner
│           │   ├── PanelMainView+Subviews.swift — subview decomposition of PanelMainView (row containers, branch/tag pills, etc.)
│           │   ├── RunnerRowViews.swift     — SwiftUI views for rendering individual runner rows in the panel list
│           │   └── WorkflowActionGroup+Progress.swift — SwiftUI extensions mapping workflow status to progress-indicator state; extracted from PanelProgressViews during dead-code cleanup
│           ├── Runner/
│           │   └── RunnerViewModel.swift    — bridges RunnerStore and LocalRunnerStore into observable properties consumed by SwiftUI views; state is pushed from stores via MainActor
│           ├── Settings/
│           │   ├── AddRunnerSheet.swift     — sheet for registering a new self-hosted runner (token fetch, timeout, keyWindow handling)
│           │   ├── AddRunnerSheet+FormFields.swift — form field subviews for AddRunnerSheet (name, URL, labels)
│           │   ├── AddRunnerSheet+TokenSection.swift — token-fetch section of the AddRunnerSheet
│           │   ├── AddRunnerSheet+Validation.swift — input validation logic for AddRunnerSheet
│           │   ├── AddScopeSheet.swift      — sheet for adding a new monitored scope (org/repo/user picker, manual entry)
│           │   ├── FailureHookCommandSheet.swift — sheet for editing the failure-hook shell command and inserting variables
│           │   ├── LocalRunnersView.swift   — settings sub-view listing locally installed self-hosted runners
│           │   ├── RunnerDetailSheet.swift  — sheet showing runner metadata and a copy-to-pasteboard token action
│           │   ├── ScopesView.swift         — settings sub-view for managing monitored scopes
│           │   ├── SettingsView.swift       — main Settings tab view (login, notifications, scopes, runners, failure hook)
│           │   └── SettingsView+Sections.swift — section decomposition helpers for SettingsView
│           ├── Sheets/
│           │   ├── BranchSelectorSheet.swift — sheet for picking a branch filter for a runner scope
│           │   └── RepoSelectorSheet.swift  — sheet for selecting a repository within the current scope
│           └── StepLog/
│               ├── LogCopyButton.swift      — button that copies the current step log to the clipboard with visual feedback
│               └── StepLogView.swift        — full-screen log viewer for a workflow step; fetches, parses, and displays raw log text
│
└── Tests/
    ├── RunnerBarCoreTests/
    │   ├── LocalRunnerIndexTests.swift      — tests for LocalRunnerIndex — the UserDefaults-backed name → install-path index
    │   ├── OrgRunnerMetricsResolutionTests.swift — tests for org-level runner metrics resolution logic
    │   ├── RunnerBarCoreTests.swift         — unit tests for RunnerBarCore models and logic
    │   └── SaveRunnerEditsUseCaseTests.swift — tests for SaveRunnerEditsUseCase using actor-based spy conformances
    └── RunnerBarUITests/
        └── RunnerBarUITests.swift           — UI test suite for RunnerBar
```
