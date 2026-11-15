#!/bin/sh
# Builds dist/AskBot-<version>.zip from the last commit (not the working folder, so
# unfinished changes never get packaged): the files the .toc loads plus the docs, inside an
# AskBot/ folder, ready to unzip into Interface/AddOns or share.
# Run from the repo:  sh tools/package.sh
set -e
cd "$(dirname "$0")/.."
version=$(git show HEAD:AskBot.toc | sed -n 's/^## Version:[[:space:]]*\([^[:space:]]*\).*/\1/p')
[ -n "$version" ] || { echo "No version in AskBot.toc"; exit 1; }
lua=$(git show HEAD:AskBot.toc | tr -d '\r' | grep -E '^[[:space:]]*[^#[:space:]].*\.lua[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
mkdir -p dist
zip="dist/AskBot-$version.zip"
rm -f "$zip"
git archive --format=zip --prefix=AskBot/ -o "$zip" HEAD AskBot.toc README.md INSTALL.txt LICENSE.md $lua
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Note: uncommitted changes were left out (the zip is HEAD, $(git rev-parse --short HEAD))."
fi
echo "Built $zip"
