#!/usr/bin/env bash
# publish.sh — local release orchestrator for RunBot.
#
# Usage:
#   ./publish.sh          # stable release  → force-pushes main → release branch
#   ./publish.sh -beta    # pre-release     → force-pushes main → beta branch
#
# CI (.github/workflows/publish.yml) triggers on push to `beta` or `release`
# and handles tagging, building, zipping, and creating the GitHub Release.
# This script is intentionally thin — all version computation lives in CI.
#
# Prerequisites:
#   - Working tree must be clean (no uncommitted changes or untracked files).
#   - Must be run from the repo root on the `main` branch (or any branch you
#     want to release; the force-push routes HEAD, not a hardcoded ref).
set -euo pipefail

# ────────────────────────────────────────────────────────────────────
# Parse arguments
# ────────────────────────────────────────────────────────────────────
BETA=false
for arg in "$@"; do
    case "$arg" in
        -beta) BETA=true ;;
        *)
            echo "error: unknown argument: $arg" >&2
            echo "usage: ./publish.sh [-beta]" >&2
            exit 1
            ;;
    esac
done

# ────────────────────────────────────────────────────────────────────
# Dirty-tree guard
# A dirty working tree means uncommitted changes would be silently excluded
# from the release build. Abort early and let the user decide what to do.
# ────────────────────────────────────────────────────────────────────
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: working tree is dirty. Commit or stash your changes before publishing." >&2
    git status --short >&2
    exit 1
fi

# ────────────────────────────────────────────────────────────────────
# Determine target branch
# ────────────────────────────────────────────────────────────────────
if [[ "$BETA" = true ]]; then
    BRANCH="beta"
else
    BRANCH="release"
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "➜ Publishing from branch '${CURRENT_BRANCH}' → '${BRANCH}'"

# ────────────────────────────────────────────────────────────────────
# Force-push HEAD to the routing branch
# --force is intentional: these branches are ephemeral CI trigger targets,
# not long-lived history branches. Every push here is a deliberate "start a
# new release build from this exact commit".
# ────────────────────────────────────────────────────────────────────
git push --force origin "HEAD:${BRANCH}"

echo ""
echo "✅ Pushed to '${BRANCH}'. CI will now tag, build, and publish the release."
echo "   Watch progress at: https://github.com/runbot-hq/run-bot/actions"
