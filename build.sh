#!/usr/bin/env bash
set -e

APP_NAME="RunnerBar"
VERSION="0.7.0"
OUT_DIR="dist"

# ── ⚠️  DO NOT CHANGE THE ARCH OR BUILD PATH BELOW ────────────────────────
# This project targets Apple Silicon (arm64) ONLY.
# The explicit --arch arm64 flag and the .build/arm64-apple-macosx/release/
# output path are INTENTIONAL. The previous arch-neutral path
# (.build/apple/Products/Release/) caused stale build artefacts that led to
# hours of wasted debugging. Do not revert to the generic path.
# ───────────────────────────────────────────────────────────────────────────
echo "→ Compiling arm64 binary..."
swift build -c release --arch arm64

echo "→ Assembling .app bundle..."
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/$APP_NAME.app/Contents/MacOS"
mkdir -p "$OUT_DIR/$APP_NAME.app/Contents/Resources"

cp ".build/arm64-apple-macosx/release/$APP_NAME" \
   "$OUT_DIR/$APP_NAME.app/Contents/MacOS/"
cp "Resources/Info.plist" \
   "$OUT_DIR/$APP_NAME.app/Contents/"

echo "→ Ad-hoc signing..."
codesign --force --deep --sign - "$OUT_DIR/$APP_NAME.app"

echo "→ Zipping..."
ditto -c -k --keepParent \
    "$OUT_DIR/$APP_NAME.app" \
    "$OUT_DIR/RunnerBar.zip"

echo "$VERSION" > "$OUT_DIR/version.txt"

echo "✓ Done — dist/RunnerBar.zip is ready"

# ── Launch via `open` (not direct binary) ───────────────────────────────────
# IMPORTANT: The OAuth callback URL scheme (runnerbar://) is registered with
# macOS Launch Services only when the .app bundle is launched via `open` or
# Finder. Running the binary directly (./dist/RunnerBar.app/Contents/MacOS/RunnerBar)
# skips LS registration, so Safari cannot route runnerbar://oauth/callback
# back to the app and shows "address is invalid" instead.
#
# Always use `open dist/RunnerBar.app` for development — this script does it
# automatically. The pkill ensures a clean restart without a stale process.
# ────────────────────────────────────────────────────────────────────────────
echo "→ Restarting app via open (registers runnerbar:// URL scheme)..."
pkill -x RunnerBar 2>/dev/null || true
sleep 0.5
open "$OUT_DIR/$APP_NAME.app"
echo "✓ RunnerBar launched"
