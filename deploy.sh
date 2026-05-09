#!/usr/bin/env bash
set -e

VERSION=$(cat dist/version.txt)
ASSET="runner-bar-${VERSION}.zip"

# Rename artifact — use mv to avoid leaving a stale dist/RunnerBar.zip
# alongside the versioned asset between runs.
echo "→ Renaming artifact for GitHub Releases..."
mv dist/RunnerBar.zip "dist/${ASSET}"

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
git commit -m "Release ${VERSION}"
git push origin gh-pages
cd ..

git worktree remove _pages --force

echo "✓ Done — https://github.com/eoncode/runner-bar/releases/tag/v${VERSION}"
