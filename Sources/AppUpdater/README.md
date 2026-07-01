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
// If you distribute a Developer ID-signed app, also set:
// updater.skipCodeSignValidation = false
// See the Trust model section below for details.
```

### 3. Drive it from your app delegate

```swift
updater.rehydrateCachedUpdateIfNewer(state: myState) // offline-ready, before any network
await updater.checkAndHandle(state: myState)          // channel-aware check + download/cache
updater.scheduleBackgroundCheck(state: myState)       // daily background re-check

// From the "Install & Relaunch" button:
await updater.installAndRelaunch(state: myState)
```

## Choosing an entry point

The library exposes two public entry-point shapes. Use `AppUpdater` for
virtually every case; `UpdateChecker` is a narrow escape hatch.

| | `AppUpdater.checkAndHandle(state:)` | `UpdateChecker.checkForUpdate(...)` |
|---|---|---|
| **What it does** | Full pipeline: check → download → cache → state mutation | Check only: returns a raw `UpdateCheckResult`; no download, no state |
| **Requires `UpdateStateProviding`** | Yes | No |
| **Works with `scheduleBackgroundCheck`** | Yes (designed for it) | No |
| **Use when** | You want the complete update flow | You need to know whether an update exists without side effects — e.g. displaying a badge without triggering a download, or in a CLI tool that manages its own install step |

If you find yourself calling `UpdateChecker.checkForUpdate` and then
manually downloading the result, switch to `AppUpdater` instead — that
pipeline is already implemented, tested, and handles the scheduler,
cache, and failure paths for you.

## Trust model

`AppUpdater` supports two distribution paths, controlled by the
`skipCodeSignValidation` flag on `AppUpdater`.

### Unsigned path — `skipCodeSignValidation = true` (default, RunBot)

Download integrity is guaranteed by the SHA-256 sidecar only:

- The release zip is downloaded and verified against the `.sha256` sidecar asset.
- No `codesign` invocation is performed on the downloaded bundle.
- The atomic bundle swap proceeds immediately after checksum verification passes.
- **Correct for apps distributed without a Developer ID signature.** RunBot is
  ad-hoc signed (no Developer ID, no notarisation), so Gatekeeper cannot validate
  a codesign identity — skipping the check is both safe and required.

```swift
let updater = AppUpdater(
    repo: "your-org/your-repo",
    currentVersion: "1.2.3",
    assetName: { _ in "YourApp.zip" },
    schedulerIdentifier: "com.your-org.update-check"
)
// skipCodeSignValidation defaults to true — no extra configuration needed
```

### Signed path — `skipCodeSignValidation = false` (external signed consumers)

For apps distributed with a Developer ID signature, enable identity verification:

1. **SHA-256 verification** runs first (always). A checksum mismatch aborts the
   install before any codesign check is attempted.
2. **`codesign -dvvv`** is run on both the running bundle (`Bundle.main`) and the
   freshly unzipped candidate bundle.
3. The `Authority=` identity strings (leaf certificate common name, e.g.
   `"Developer ID Application: Acme Corp (XXXXXXXX)"`) must match exactly.
4. A mismatch calls `state.setUpdateFailed()` and aborts the install. No bundle
   swap is performed.

```swift
let updater = AppUpdater(
    repo: "your-org/your-repo",
    currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
    assetName: { _ in "YourApp.zip" },
    schedulerIdentifier: "com.your-org.update-check"
)
updater.skipCodeSignValidation = false // enable identity check for Developer ID builds
```

> **Note:** Set `skipCodeSignValidation` before calling `scheduleBackgroundCheck`
> or `checkAndHandle`. The value is read at `installAndRelaunch` time, but
> establishing it early removes any ambiguity about which value was in effect
> when a background check fired.

> **Why `codesign -dvvv` instead of the Security framework?**
> The subprocess approach avoids Hardened Runtime entitlement requirements and
> produces the same `Authority=` string that developers already see in Console.app.
> `SecCode`/`SecRequirement` would require additional entitlements and add
> framework complexity for equivalent security guarantees.

## Distribution assumptions

- The release archive carries exactly one `.app` at its root.
- Each release attaches a `<assetName>.sha256` sidecar.
- **Missing zip asset or missing sidecar** (checksumURL is nil on the
  `AvailableRelease`) → `state.setAssetMissing()` is called. This is the cue
  to direct the user to the curl-install fallback — not a generic retry.
  `setDownloadStarted()` is never called in this path.
- **Download or verification failure** (network error, HTTP non-200, checksum
  mismatch, empty sidecar body) → `state.setUpdateFailed()` is called. The host
  should direct the user to re-run the original `curl` install command — **not**
  open a browser download. Downloading via a browser stamps the `.app` with
  `com.apple.quarantine`, which triggers Gatekeeper and breaks the install.

## Persisted state

Two `UserDefaults` keys scoped by `schedulerIdentifier` survive a relaunch so a
downloaded-but-not-yet-installed update is offered again on next launch:

- `<domain>.cachedUpdateZipPath`
- `<domain>.cachedUpdateVersion`

The verified zip is cached at `~/Library/Caches/<schedulerIdentifier>/update-<version>.zip`.

## Logging

Messages appear in Console.app under subsystem `io.github.appupdater`, category `AppUpdater`.
`.debug` calls are elided at zero cost in release builds when no one is streaming.

## Known limitations

### 100-release ceiling

`AppUpdater` fetches releases with `per_page=100` and makes a single request —
no pagination. If your repository has published more than 100 releases, releases
beyond the first page are never evaluated. In practice the newest release is
always in the first page (GitHub returns releases newest-first by default), so
this is not a correctness problem for the common case.

It becomes a problem only if you publish hotfixes to old branches and those
releases sort after the 100th entry by semver. Recommended mitigations:
- Keep total published releases ≤ 100 by converting old releases to drafts.
- Or tag hotfixes with a version that sorts into the top 100 by semver.

Pagination support is a future enhancement if there is demand.

### `beta.N` pre-release labels only

`UpdateChecker.isNewer` supports pre-release ordering **only for `beta.N` labels**
(e.g. `v0.8.0-beta.2` > `v0.8.0-beta.1`). Any other pre-release suffix —
`rc.1`, `alpha.1`, or an arbitrary string — is parsed with a nil beta index.
When both versions share the same `major.minor.patch` and at least one has a
non-`beta.N` pre-release label, `isNewer` returns `false`.

The current publish pipeline only generates `beta.N` tags, so this is not a
problem in practice. If you add an RC channel, extend `ParsedVersion` in
`UpdateChecker.swift` to recognise the new suffix before relying on `isNewer`
for ordering.

## Alternatives

- [Sparkle](https://github.com/sparkle-project/Sparkle) — the standard choice; supports sandboxed apps, Appcast XML, delta updates, and built-in UI
- [s1ntoneli/AppUpdater](https://github.com/s1ntoneli/AppUpdater) — GitHub Releases-based like this library but with SwiftUI UI, code-sign validation, and localized changelogs
