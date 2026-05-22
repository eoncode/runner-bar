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
├── Sources/RunnerBar/
│   ├── main.swift                 # NSApp bootstrap, lifecycle
│   ├── MenuBar.swift              # NSStatusItem + popover
│   ├── GitHub.swift               # shells out to `gh api`, parses runners
│   └── Runners.swift              # runner model + 30s polling
├── Resources/
│   └── Info.plist                 # LSUIElement=true, bundle metadata
├── build.sh                       # compile → .app bundle → ad-hoc sign → zip
├── deploy.sh                      # push dist/ to gh-pages branch
├── install.sh                     # curl | bash target (also lives on gh-pages)
├── DEVELOPMENT.md
├── DEPLOYMENT.md
└── AGENTS.md                      # instructions for AI coding agents
```

---

## Editor

No IDE required. Use whatever you prefer:

- **AI agent (recommended)** — provide `AGENTS.md` as context, let the agent write and patch Swift files directly
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

## Auth during development

The app shells out to `gh auth token` at runtime to get the GitHub token. As long as you have run `gh auth login` once, this works automatically — no config needed.

If you want to test with a specific token:
```bash
export GH_TOKEN=ghp_yourtoken
swift run
```

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

This produces `dist/RunnerBar.zip` — the distributable. See `DEPLOYMENT.md` for how to publish it.

---

## Working with AI agents

See `AGENTS.md` for the system prompt context that tells agents:
- This is a SwiftPM project, no Xcode
- Build command is `swift build`
- Run command is `swift run`
- Target is macOS 13+
- No Interface Builder, all UI is programmatic
- Auth is via `gh auth token` shell-out
