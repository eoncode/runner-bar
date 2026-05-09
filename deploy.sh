#!/usr/bin/env bash
set -e

VERSION=$(cat dist/version.txt)
ASSET="runner-bar-${VERSION}.zip"

# Preflight: fail fast with a clear message if the build artifact is missing.
# build.sh produces the correctly-named zip directly — no mv step needed.
if [ ! -f "dist/${ASSET}" ]; then
  echo "✗ dist/${ASSET} not found — run build.sh first" >&2
  exit 1
fi

# GitHub Release — required for AppUpdater asset discovery (ref #345).
# Use a create-or-upload pattern so CI retries and manual re-runs for the
# same tag don't fail under set -e. --clobber is only valid on
# `gh release upload`, not `gh release create`.
echo "→ Publishing GitHub Release ${VERSION}..."
if gh release view "v${VERSION}" >/dev/null 2>&1; then
  # Release already exists — overwrite the asset in-place.
  gh release upload "v${VERSION}" "dist/${ASSET}" --clobber
else
  gh release create "v${VERSION}" \
    "dist/${ASSET}" \
    --title "v${VERSION}" \
    --notes "Release ${VERSION}"
fi

# gh-pages — kept for install.sh bootstrap (curl | bash first-install).
echo "→ Deploying to gh-pages for install.sh bootstrap..."
if [ ! -d "_pages" ]; then
    git worktree add _pages gh-pages
fi

# Re-copy under the original name so install.sh download URL stays stable.
cp "dist/${ASSET}" _pages/RunnerBar.zip
cp dist/version.txt _pages/
cp install.sh _pages/

cd _pages
git add -A
# Guard: git commit exits non-zero if nothing changed (e.g. re-deploy of same
# version). Under set -e this would abort before push and worktree cleanup.
git diff --cached --quiet || git commit -m "Release ${VERSION}"
git push origin gh-pages
cd ..

git worktree remove _pages --force

echo "✓ Done — https://github.com/eoncode/runner-bar/releases/tag/v${VERSION}"
