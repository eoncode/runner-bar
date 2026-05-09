#!/usr/bin/env bash
set -e

VERSION=$(cat dist/version.txt)
ASSET="runner-bar-${VERSION}.zip"

echo "→ Renaming artifact for GitHub Releases..."
cp dist/RunnerBar.zip "dist/${ASSET}"

# GitHub Release — required for AppUpdater asset discovery (ref #345).
# AppUpdater looks for an asset named <repo>-<semver>.zip on the release.
echo "→ Creating GitHub Release $VERSION..."
gh release create "v${VERSION}" \
  "dist/${ASSET}" \
  --title "v${VERSION}" \
  --notes "Release $VERSION"

# gh-pages — kept for install.sh bootstrap (curl | bash first-install).
echo "→ Deploying to gh-pages for install.sh bootstrap..."
if [ ! -d "_pages" ]; then
    git worktree add _pages gh-pages
fi

cp dist/RunnerBar.zip _pages/
cp dist/version.txt _pages/
cp install.sh _pages/

cd _pages
git add -A
git commit -m "Release $VERSION"
git push origin gh-pages
cd ..

git worktree remove _pages --force

echo "✓ Done — https://github.com/eonist/runner-bar/releases/tag/v${VERSION}"
