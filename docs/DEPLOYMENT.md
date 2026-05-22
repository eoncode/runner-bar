# Deployment

## Overview

RunnerBar is distributed as a pre-built `.app` bundle, zipped and hosted on GitHub Pages. End users install with a single `curl` command — no Gatekeeper dialog, no Apple Developer account, no Xcode.

```bash
curl -fsSL https://eonist.github.io/runner-bar/install.sh | bash
```

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
├── RunnerBar.zip       ← pre-built universal .app bundle
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

# 4. Zip (preserves symlinks and resource forks)
ditto -c -k --keepParent \
  "$OUT_DIR/$APP_NAME.app" \
  "$OUT_DIR/RunnerBar.zip"

echo "$VERSION" > "$OUT_DIR/version.txt"

echo "✓ Built $APP_NAME.zip ($VERSION)"
```

---

## Deploy pipeline

After running `build.sh`, push the output to the `gh-pages` branch:

```bash
#!/usr/bin/env bash
set -e

# Checkout or create gh-pages branch
git fetch origin gh-pages 2>/dev/null || true
git worktree add _pages gh-pages 2>/dev/null || \
  git worktree add _pages --orphan gh-pages

# Copy build artifacts
cp dist/RunnerBar.zip _pages/
cp dist/version.txt _pages/
cp install.sh _pages/

# Commit and push
cd _pages
git add -A
git commit -m "Release $(cat version.txt)"
git push origin gh-pages
cd ..
git worktree remove _pages

echo "✓ Deployed to https://eonist.github.io/runner-bar/"
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
| `https://eonist.github.io/runner-bar/RunnerBar.zip` | Universal `.app` bundle |
| `https://eonist.github.io/runner-bar/version.txt` | Current version string |

---

## Versioning

- Version is set manually in `build.sh` as `VERSION="x.y.z"`
- Bump and re-run `build.sh` + deploy script for each release
- No CI automation in v0.1 — fully manual release process
