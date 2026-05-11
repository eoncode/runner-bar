# Deployment

## Overview

RunnerBar is distributed as a pre-built `.app` bundle, zipped and hosted on GitHub Pages. End users install with a single `curl` command — no Gatekeeper dialog, no Apple Developer account, no Xcode.

```bash
curl -fsSL https://eonist.github.io/runner-bar/install.sh | bash
```

---

## Repository Owner Clarification

RunnerBar lives under **two** GitHub accounts, each serving a different purpose:

| Account | URL | Role |
|---------|-----|------|
| `eoncode` | `https://github.com/eoncode/runner-bar` | Source code, GitHub Releases, AppUpdater asset discovery |
| `eonist` | `https://eonist.github.io/runner-bar/` | GitHub Pages (gh-pages branch), `install.sh` bootstrap |

`AppUpdaterService` is configured with `owner: "eoncode"` because `AppUpdater` fetches assets from **GitHub Releases** (the API endpoint `repos/eoncode/runner-bar/releases`). The gh-pages URL under `eonist` is only used for the initial `curl | bash` first-install flow; it is never consulted during in-app update checks.

> ⚠️ If the repository is ever transferred or mirrored, update `owner:` and `repo:` in `AppUpdaterService.swift` **and** update the GitHub Pages source to match.

---

## Ad-hoc Signing & `skipCodeSignValidation`

### What it does

`AppUpdater` by default validates that the downloaded `.app` bundle is signed by the **same certificate** as the running app before installing. Setting `skipCodeSignValidation = true` disables this check and allows installation of any bundle whose zip asset name matches the expected `runner-bar-<VERSION>.zip` pattern.

### Why it is safe here

RunnerBar uses **ad-hoc signing** (`codesign --force --deep --sign -`) rather than a Developer ID certificate. Ad-hoc signatures are machine-local: they cannot be verified on another machine, so `AppUpdater`'s default certificate-match check would always fail and block every update. Disabling it is the only viable path without a paid Apple Developer account.

This is safe under the following conditions — **all of which currently hold**:

1. **The release pipeline is controlled.** Only `eoncode/runner-bar` maintainers can publish GitHub Releases under that repo. The asset download URL is `https://github.com/eoncode/runner-bar/releases/download/<tag>/runner-bar-<VERSION>.zip` — an attacker cannot publish there without write access to the repo.
2. **The repo is private or under active maintainer oversight.** GitHub's release asset hosting is not a public CDN that third parties can inject into.
3. **Transport security is enforced.** `AppUpdater` downloads over HTTPS; TLS certificate pinning is handled by macOS's URLSession stack.

### Accepted risk

| Risk | Mitigation |
|------|-----------|
| Compromised `eoncode` org credentials could publish a malicious release | Enable GitHub org 2FA; restrict release publishing to protected tags via branch rules |
| No code-signing chain of trust for the downloaded bundle | Accepted: ad-hoc signing is the explicit design choice for this tool (no paid Dev account) |
| Future `AppUpdater` version may change validation behaviour | `Package.swift` pins `.exact("0.1.9")` — bumping requires a deliberate, reviewed change |

> ⚠️ **Before enabling Developer ID signing:** remove `skipCodeSignValidation = true` from `AppUpdaterService.swift`. The default validation will then correctly verify the certificate chain and this trade-off no longer applies.

---

## How GitHub Pages is set up

This repo uses the `gh-pages` branch as the GitHub Pages source, served at:

```
https://eonist.github.io/runner-bar/
```

To enable:
1. Go to **Settings → Pages** in this repo
2. Set **Source** to `Deploy from a branch`
3. Set **Branch** to `gh-pages`, folder `/` (root)
4. Save

Files hosted on `gh-pages`:

```
gh-pages/
├── install.sh          ← the curl | bash target
├── RunnerBar.zip       ← pre-built universal .app bundle (stable name for install.sh)
└── version.txt         ← current version string, e.g. 0.1.0
```

---

## Build pipeline (`build.sh`)

Run on the developer machine (arm64 Mac with Swift CLT installed):

```bash
#!/usr/bin/env bash
set -e

APP_NAME="RunnerBar"
VERSION="0.1.0"
OUT_DIR="dist"

# 1. Compile universal binary
swift build -c release --arch arm64 --arch x86_64

# 2. Assemble .app bundle
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/$APP_NAME.app/Contents/MacOS"
mkdir -p "$OUT_DIR/$APP_NAME.app/Contents/Resources"

cp ".build/apple/Products/Release/$APP_NAME" \
   "$OUT_DIR/$APP_NAME.app/Contents/MacOS/"
cp Resources/Info.plist \
   "$OUT_DIR/$APP_NAME.app/Contents/"

# 3. Ad-hoc sign (required for Apple Silicon)
codesign --force --deep --sign - "$OUT_DIR/$APP_NAME.app"

# 4. Zip — two outputs:
#    runner-bar-VERSION.zip  → GitHub Releases (AppUpdater asset discovery)
#    RunnerBar.zip           → gh-pages (install.sh stable URL)
ditto -c -k --keepParent \
  "$OUT_DIR/$APP_NAME.app" \
  "$OUT_DIR/runner-bar-${VERSION}.zip"
cp "$OUT_DIR/runner-bar-${VERSION}.zip" "$OUT_DIR/RunnerBar.zip"

echo "$VERSION" > "$OUT_DIR/version.txt"

echo "✓ Built $APP_NAME ($VERSION)"
```

---

## Deploy pipeline

`deploy.sh` handles both GitHub Releases (for AppUpdater) and gh-pages (for install.sh):

```bash
#!/usr/bin/env bash
set -e

VERSION=$(cat dist/version.txt)
ASSET="runner-bar-${VERSION}.zip"

# Preflight: fail fast if the build artifact is missing.
if [ ! -f "dist/${ASSET}" ]; then
  echo "✗ dist/${ASSET} not found — run build.sh first" >&2
  exit 1
fi

# GitHub Release — required for AppUpdater asset discovery.
echo "→ Publishing GitHub Release ${VERSION}..."
if gh release view "v${VERSION}" >/dev/null 2>&1; then
  gh release upload "v${VERSION}" "dist/${ASSET}" --clobber
else
  gh release create "v${VERSION}" \
    "dist/${ASSET}" \
    --title "v${VERSION}" \
    --notes "Release ${VERSION}"
fi

# gh-pages — kept for install.sh bootstrap.
echo "→ Deploying to gh-pages..."
if [ ! -d "_pages" ]; then
    git worktree add _pages gh-pages
fi

cp "dist/${ASSET}" _pages/RunnerBar.zip
cp dist/version.txt _pages/
cp install.sh _pages/

cd _pages
git add -A
git diff --cached --quiet || git commit -m "Release ${VERSION}"
git push origin gh-pages
cd ..

git worktree remove _pages --force

echo "✓ Done — https://github.com/eoncode/runner-bar/releases/tag/v${VERSION}"
```

---

## `install.sh`

This file lives at the root of `gh-pages` and is the single URL users run:

```bash
#!/usr/bin/env bash
set -e

BASE="https://eonist.github.io/runner-bar"
TMP=$(mktemp -d)

echo "→ Downloading RunnerBar..."
curl -fsSL "$BASE/RunnerBar.zip" -o "$TMP/RunnerBar.zip"

echo "→ Installing to /Applications..."
rm -rf /Applications/RunnerBar.app
unzip -qo "$TMP/RunnerBar.zip" -d /Applications

rm -rf "$TMP"

echo "→ Launching..."
open /Applications/RunnerBar.app

echo "✓ RunnerBar installed"
```

**Why no Gatekeeper fires:**
`curl` does not set the `com.apple.quarantine` extended attribute on downloaded files. Gatekeeper is only triggered by that attribute. The `.app` lands in `/Applications` clean and opens without any security dialog.

---

## URL structure

| URL | Contents |
|-----|----------|
| `https://eonist.github.io/runner-bar/install.sh` | Installer script |
| `https://eonist.github.io/runner-bar/RunnerBar.zip` | Universal `.app` bundle (stable name) |
| `https://eonist.github.io/runner-bar/version.txt` | Current version string |
| `https://github.com/eoncode/runner-bar/releases/latest` | Latest GitHub Release (AppUpdater source) |

---

## Versioning

- Version is set manually in `build.sh` as `VERSION="x.y.z"`
- Bump and re-run `build.sh` + `deploy.sh` for each release
- No CI automation in v0.1 — fully manual release process
- `AppUpdater` polls `eoncode/runner-bar` GitHub Releases every 24 h via `NSBackgroundActivityScheduler`; the version string in `version.txt` and the GitHub Release tag must stay in sync
