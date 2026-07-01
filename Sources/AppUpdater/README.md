# AppUpdater

A host-agnostic Swift library that drives an in-app auto-update flow
for macOS apps distributed outside the Mac App Store. Zero host-specific
dependencies — all host values (repo slug, asset name, scheduler identifier,
beta-channel preference, UI state model) are injected by the caller.

## Caveats

- macOS 26+ only
- Non-sandboxed apps only
- GitHub Releases as the distribution source (no other providers)
- No built-in UI — the host owns all update state and surfaces it however it likes

## Flow

```
GitHub Releases poll → semver compare (incl. beta.N) → zip download
    → SHA-256 sidecar verification → cache → host state mutation
    → install & relaunch on user confirmation
```

## Quick start

### 1. Conform your state model to `UpdateStateProviding`

```swift
extension MyUpdateState: UpdateStateProviding {}
```

All properties are read-only `{ get }`; mutations go through named methods
(`setDownloadComplete`, `setUpdateFailed`, etc.) so no caller can write
`updateZipURL` without also setting the paired version.

### 2. Construct the updater

```swift
let updater = AppUpdater(
    repo: "your-org/your-repo",
    currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
    assetName: { _ in "YourApp.zip" },               // SHA-256 sidecar expected at "<assetName>.sha256"
    schedulerIdentifier: "com.your-org.update-check" // also scopes UserDefaults keys
)
```

### 3. Drive it from your app delegate

```swift
updater.rehydrateCachedUpdateIfNewer(state: myState) // offline-ready, before any network
await updater.checkAndHandle(state: myState)          // channel-aware check + download/cache
updater.scheduleBackgroundCheck(state: myState)       // daily background re-check

// From the "Install & Relaunch" button:
await updater.installAndRelaunch(state: myState)
```

## Distribution assumptions

- The release archive carries exactly one `.app` at its root.
- Each release attaches a `<assetName>.sha256` sidecar. A missing sidecar is a hard failure.
- On any download or install failure `setUpdateFailed()` is called. The host should direct
  the user to re-run the original `curl` install command — **not** open a browser download.
  Downloading via a browser stamps the `.app` with `com.apple.quarantine`, which triggers
  Gatekeeper and breaks the install. The curl path intentionally bypasses this.

## Persisted state

Two `UserDefaults` keys scoped by `schedulerIdentifier` survive a relaunch so a
downloaded-but-not-yet-installed update is offered again on next launch:

- `<domain>.cachedUpdateZipPath`
- `<domain>.cachedUpdateVersion`

The verified zip is cached at `~/Library/Caches/<schedulerIdentifier>/update-<version>.zip`.

## Logging

Messages appear in Console.app under subsystem `io.github.appupdater`, category `AppUpdater`.
`.debug` calls are elided at zero cost in release builds when no one is streaming.

## Alternatives

- [Sparkle](https://github.com/sparkle-project/Sparkle) — the standard choice; supports sandboxed apps, Appcast XML, delta updates, and built-in UI
- [s1ntoneli/AppUpdater](https://github.com/s1ntoneli/AppUpdater) — GitHub Releases-based like this library but with SwiftUI UI, code-sign validation, and localized changelogs
