#!/usr/bin/env bash
set -e

BASE="https://runbot-hq.github.io/run-bot"
TMP=$(mktemp -d)

echo "→ Downloading RunBot..."
curl -fsSL -L "$BASE/RunBot.zip" -o "$TMP/RunBot.zip"

echo "→ Installing to /Applications..."
rm -rf /Applications/RunBot.app
unzip -qo "$TMP/RunBot.zip" -d /Applications

rm -rf "$TMP"

echo "→ Launching..."
open /Applications/RunBot.app

echo "✓ RunBot installed"
