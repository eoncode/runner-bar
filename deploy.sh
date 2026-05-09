#!/usr/bin/env bash
set -e

VERSION=$(cat dist/version.txt)

echo "→ Deploying $VERSION to gh-pages (curl bootstrap)..."

if [ ! -d "_pages" ]; then
    git worktree add _pages gh-pages
fi

# Keep gh-pages updated for the curl bootstrap installer (install.sh).
# install.sh downloads the fixed name RunnerBar.zip — do NOT change this filename.
cp "dist/runner-bar-${VERSION}.zip" _pages/RunnerBar.zip
cp dist/version.txt _pages/
cp install.sh _pages/

cd _pages
git add -A
git commit -m "Release $VERSION"
git push origin gh-pages
cd ..

git worktree remove _pages --force

# Publish a GitHub Release with the versioned zip as an asset.
# AppUpdater polls GitHub Releases for runner-bar-<version>.zip assets.
# Guard against re-running deploy for the same version (e.g. after a build fix).
if gh release view "v${VERSION}" &>/dev/null; then
    echo "→ Release v${VERSION} already exists, skipping create."
else
    echo "→ Creating GitHub Release v${VERSION}..."
    gh release create "v${VERSION}" \
        "dist/runner-bar-${VERSION}.zip" \
        --title "v${VERSION}" \
        --notes "Release ${VERSION}"
    echo "✓ GitHub Release — https://github.com/eonist/runner-bar/releases/tag/v${VERSION}"
fi

echo "✓ Deployed — https://eonist.github.io/runner-bar/"
