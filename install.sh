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
