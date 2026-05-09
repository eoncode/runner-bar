#!/usr/bin/env bash
set -e

VERSION=$(cat dist/version.txt)
ASSET="runner-bar-${VERSION}.zip"

# Rename artifact — use mv to avoid leaving a stale dist/RunnerBar.zip
# alongside the versioned asset between runs.
echo "→ Renaming artifact for GitHub Releases..."
mv dist/RunnerBar.zip "dist/${ASSET}"

# GitHub Release — required for AppUpdater asset discovery (ref #345).
# --clobber overwrites an existing release for this tag so CI retries
# and manual re-runs don't fail with set -e when the tag already exists.
echo "→ Creating GitHub Release ${VERSION}..."
gh release create "v${VERSION}" \
  "dist/${ASSET}" \
  --title "v${VERSION}" \
  --notes "Release ${VERSION}" \
  --clobber

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
