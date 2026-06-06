# Development

## Philosophy

- No Xcode IDE — SwiftPM only
- No `.xcodeproj`, no storyboards, no Interface Builder
- Written with AI assistance, built and run in terminal
- macOS 13+ target, universal binary (arm64 + x86_64)

---

## Prerequisites

You need the Swift toolchain. Two options — pick one:

**Option A: Xcode Command Line Tools** (~1 GB, easiest)
```bash
xcode-select --install
```

**Option B: Standalone Swift toolchain** (no Apple branding)
Download from https://swift.org/download and follow the installer.

Verify:
```bash
swift --version
# Swift version 5.9+ required
```

You also need `gh` CLI installed and authenticated:
```bash
brew install gh
gh auth login
```

---

## Project structure

```
runner-bar/
├── Package.swift                  # SwiftPM manifest — the only build config
├── project.yml                    # Project metadata / config
├── Sources/RunnerBar/
│   ├── main.swift                 # NSApp bootstrap, lifecycle
│   ├── Exports.swift              # Public re-exports
│   ├── App/                       # App-level setup and delegates
│   ├── DesignSystem/              # Shared UI tokens, styles, components
│   ├── GitHub/                    # GitHub API integration (URLSession-based)
│   ├── Models/                    # Data models (Runner, Workflow, etc.)
│   ├── Panel/                     # Popover/panel UI
│   ├── Preferences/               # User preferences / settings UI
│   ├── Runner/                    # Runner state and polling logic
│   ├── Scope/                     # OAuth scope handling
│   ├── Services/                  # Background services, timers
│   └── Views/                     # Reusable UI views
├── Resources/
│   └── Info.plist                 # LSUIElement=true, bundle metadata
├── Tests/                         # Unit tests (SwiftPM test target)
├── .github/                       # GitHub Actions workflows
├── .swiftlint.yml                 # SwiftLint configuration
├── .periphery.yml                 # Periphery (dead code) configuration
├── build.sh                       # compile → .app bundle → ad-hoc sign → zip
├── deploy.sh                      # push dist/ to gh-pages branch
├── install.sh                     # curl | bash target (also lives on gh-pages)
└── docs/
    ├── DEVELOPMENT.md             # This file
    ├── DEPLOYMENT.md
    └── AGENTS.md                  # Instructions for AI coding agents
```

---

## Editor

No IDE required. Use whatever you prefer:

- **AI agent (recommended)** — provide `docs/AGENTS.md` as context, let the agent write and patch Swift files directly
- Any text editor for manual edits

There are no project files, schemes, or workspace configs to worry about. The only build config is `Package.swift`.

---

## Dev loop

### Run during development
```bash
swift run
```
Compiles incrementally and launches the app. The menu bar icon appears immediately. `Ctrl+C` to stop.

### Rebuild after changes
```bash
swift build
```
Checks for errors without launching. Faster feedback cycle.

### Clean build
```bash
swift package clean && swift build
```

### Check Swift version / resolved deps
```bash
swift package show-dependencies
```

---

## Linting

SwiftLint is configured via `.swiftlint.yml`. Run it locally before committing:
```bash
swiftlint
```

Dead code analysis is configured via `.periphery.yml`. Run with:
```bash
periphery scan
```

Both tools are also enforced in CI via GitHub Actions (`.github/workflows/`).

---

## Tests

Run the test suite with:
```bash
swift test
```

Tests live under `Tests/`. Add new tests alongside any new `Services/`, `Models/`, or `GitHub/` logic.

---

## Auth during development

The app uses `URLSession` with the GitHub REST API directly. It obtains a token via `gh auth token` at runtime. As long as you have run `gh auth login` once, this works automatically — no config needed.

If you want to test with a specific token:
```bash
export GH_TOKEN=ghp_yourtoken
swift run
```

The `Scope/` module handles verifying that the token has the required OAuth scopes at startup.

---

## Adding dependencies

Add to `Package.swift` under `dependencies` and run:
```bash
swift package resolve
```

No lockfile conflicts, no Xcode project to regenerate.

---

## Building for release

```bash
bash build.sh
```

This produces `dist/RunnerBar.zip` — the distributable. See `docs/DEPLOYMENT.md` for how to publish it.

---

## Working with AI agents

See `docs/AGENTS.md` for the system prompt context that tells agents:
- This is a SwiftPM project, no Xcode
- Build command is `swift build`
- Run command is `swift run`
- Target is macOS 13+
- No Interface Builder, all UI is programmatic
- Auth is via `gh auth token` shell-out
- Source is organized into focused subdirectories under `Sources/RunnerBar/`
