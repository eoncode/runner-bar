#!/usr/bin/env bash
set -e

APP_NAME="RunnerBar"
VERSION="0.2.0"
OUT_DIR="dist"

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
