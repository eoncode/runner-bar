#!/usr/bin/env bash
set -e

APP_NAME="RunnerBar"
VERSION="0.7.0"
OUT_DIR="dist"

# ---------------------------------------------------------------------------
# Phase 4 / #342-#9 (issue #326): inject OAuth client credentials at compile
# time. Fails the build immediately if credentials are absent or still set to
# placeholder values so release binaries never ship non-functional OAuth.
#
# Usage:
#   RUNNERBAR_CLIENT_ID=xxx RUNNERBAR_CLIENT_SECRET=yyy ./build.sh
# ---------------------------------------------------------------------------
CLIENT_ID="${RUNNERBAR_CLIENT_ID:-}"
CLIENT_SECRET="${RUNNERBAR_CLIENT_SECRET:-}"

if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" = "PLACEHOLDER_CLIENT_ID" ]; then
    echo "❌ ERROR: RUNNERBAR_CLIENT_ID is unset or still a placeholder." >&2
    echo "       Set a real GitHub OAuth App client ID before building." >&2
    exit 1
fi

if [ -z "$CLIENT_SECRET" ] || [ "$CLIENT_SECRET" = "PLACEHOLDER_CLIENT_SECRET" ]; then
    echo "❌ ERROR: RUNNERBAR_CLIENT_SECRET is unset or still a placeholder." >&2
    echo "       Set a real GitHub OAuth App client secret before building." >&2
    exit 1
fi

# Escape characters that could break the Swift heredoc or shell interpretation:
# backslash, ampersand, forward-slash (sed substitution delimiters),
# backtick (shell command substitution), double-quote, and dollar sign.
ESCAPED_ID=$(printf '%s' "$CLIENT_ID" \
    | sed 's/\\/\\\\/g; s/&/\\&/g; s/\//\\\//g; s/`/\\`/g; s/"/\\"/g; s/\$/\\$/g')
ESCAPED_SECRET=$(printf '%s' "$CLIENT_SECRET" \
    | sed 's/\\/\\\\/g; s/&/\\&/g; s/\//\\\//g; s/`/\\`/g; s/"/\\"/g; s/\$/\\$/g')

# Generate Secrets.swift from the committed template.
cp Sources/RunnerBar/Secrets.swift.template Sources/RunnerBar/Secrets.swift
sed -i '' \
    -e "s/PLACEHOLDER_CLIENT_ID/${ESCAPED_ID}/g" \
    -e "s/PLACEHOLDER_CLIENT_SECRET/${ESCAPED_SECRET}/g" \
    Sources/RunnerBar/Secrets.swift

echo "→ Compiling universal binary..."
swift build -c release --arch arm64 --arch x86_64

echo "→ Assembling .app bundle..."
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/$APP_NAME.app/Contents/MacOS"
mkdir -p "$OUT_DIR/$APP_NAME.app/Contents/Resources"

cp ".build/apple/Products/Release/$APP_NAME" \
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
