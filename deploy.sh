#!/usr/bin/env bash
set -e

VERSION=$(cat dist/version.txt)

echo "→ Deploying \"${VERSION}\" to gh-pages..."

if [ ! -d "_pages" ]; then
    git worktree add _pages gh-pages
fi

cp dist/RunnerBar.zip _pages/
cp dist/version.txt _pages/
cp install.sh _pages/

cd _pages
git add -A
git commit -m "Release ${VERSION}"
git push origin gh-pages
cd ..

git worktree remove _pages --force

echo "✓ Deployed — https://eonist.github.io/runner-bar/"
