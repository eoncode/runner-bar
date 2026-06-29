# Deployment

## Overview

RunBot is distributed as a pre-built `.app` bundle, zipped and hosted on GitHub Pages. End users install with a single `curl` command — no Gatekeeper dialog, no Apple Developer account, no Xcode.

```bash
curl -fsSL https://runbot-hq.github.io/run-bot/install.sh | bash
```

> **Architecture:** RunBot requires Apple Silicon (arm64). The build pipeline produces an arm64-only binary. Intel Macs are not supported.

---

## How GitHub Pages is set up

This repo uses the `gh-pages` branch as the GitHub Pages source, served at:

```
https://runbot-hq.github.io/run-bot/
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
├── RunBot.zip       ← pre-built arm64 .app bundle
└── version.txt         ← current version string, e.g. 0.1.0
```

---

## Build pipeline (`build.sh`)

Run on the developer machine (Apple Silicon Mac with Swift CLT installed):

```bash
#!/usr/bin/env bash
set -e

APP_NAME="RunBot"
VERSION="0.1.0"
OUT_DIR="dist"

# 1. Compile arm64 binary
swift build -c release --arch arm64

# 2. Assemble .app bundle
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/$APP_NAME.app/Contents/MacOS"
mkdir -p "$OUT_DIR/$APP_NAME.app/Contents/Resources"

BUILD_PATH=".build/arm64-apple-macosx/release/$APP_NAME"
if [ ! -f "$BUILD_PATH" ]; then
  echo "✗ Binary not found at $BUILD_PATH — build may have failed or output path changed"
  exit 1
fi
cp "$BUILD_PATH" "$OUT_DIR/$APP_NAME.app/Contents/MacOS/"
cp Resources/Info.plist \
   "$OUT_DIR/$APP_NAME.app/Contents/"

# 3. Ad-hoc sign (required for Apple Silicon)
codesign --force --deep --sign - "$OUT_DIR/$APP_NAME.app"

# 4. Zip (preserves symlinks and resource forks)
ditto -c -k --keepParent \
  "$OUT_DIR/$APP_NAME.app" \
  "$OUT_DIR/RunBot.zip"

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
cp dist/RunBot.zip _pages/
cp dist/version.txt _pages/
cp install.sh _pages/

# Commit and push
cd _pages
git add -A
git commit -m "Release $(cat version.txt)"
git push origin gh-pages
cd ..
git worktree remove _pages

echo "✓ Deployed to https://runbot-hq.github.io/run-bot/"
```

---

## `install.sh`

This file lives at the root of `gh-pages` and is the single URL users run:

```bash
#!/usr/bin/env bash
set -e

BASE="https://runbot-hq.github.io/run-bot"
TMP=$(mktemp -d)

echo "→ Downloading RunBot..."
curl -fsSL "$BASE/RunBot.zip" -o "$TMP/RunBot.zip"

echo "→ Installing to /Applications..."
rm -rf /Applications/RunBot.app
unzip -qo "$TMP/RunBot.zip" -d /Applications

rm -rf "$TMP"

echo "→ Launching..."
open /Applications/RunBot.app

echo "✓ RunBot installed"
```

**Why no Gatekeeper fires:**
`curl` does not set the `com.apple.quarantine` extended attribute on downloaded files. Gatekeeper is only triggered by that attribute. The `.app` lands in `/Applications` clean and opens without any security dialog.

---

## URL structure

| URL | Contents |
|-----|----------|
| `https://runbot-hq.github.io/run-bot/install.sh` | Installer script |
| `https://runbot-hq.github.io/run-bot/RunBot.zip` | arm64 `.app` bundle |
| `https://runbot-hq.github.io/run-bot/version.txt` | Current version string |

---

## Versioning

- Version is set manually in `build.sh` as `VERSION="x.y.z"`
- Bump and re-run `build.sh` + deploy script for each release
- No CI automation in v0.1 — fully manual release process


## Quick deploy

```bash
git pull && git fetch && bash build.sh && (pkill RunBot || true) && sleep 1 && open dist/RunBot.app 2>&1
bash build.sh && bash deploy.sh
curl -fsSL https://runbot-hq.github.io/run-bot/install.sh | bash
```
