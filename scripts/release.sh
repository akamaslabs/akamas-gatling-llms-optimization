#!/bin/bash
# Cuts a version release: bumps package.json's version, commits, creates an annotated
# git tag, and pushes both. Pushing a `v*.*.*` tag triggers
# .github/workflows/build-and-push.yml, which builds and publishes the image tagged with
# that version (ghcr.io/akamaslabs/akamas-gatling-llms-optimization:<version>, plus
# :<major>.<minor> and :latest) and cuts a GitHub Release from the tag.
#
# Usage: scripts/release.sh [patch|minor|major|<explicit-semver>]   (default: patch)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUMP="${1:-patch}"

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree has uncommitted changes — commit or stash before releasing." >&2
  exit 1
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo "Not on main (on '$CURRENT_BRANCH') — releases are cut from main." >&2
  exit 1
fi

git pull --ff-only

# `npm version` bumps package.json, commits "vX.Y.Z", and creates a matching
# annotated git tag in one step — see package.json for the version this bumps from.
npm version "$BUMP" -m "chore(release): v%s"

git push
git push --tags

NEW_VERSION="$(node -p "require('./package.json').version")"
echo "Pushed v${NEW_VERSION}. CI will build ghcr.io/akamaslabs/akamas-gatling-llms-optimization:${NEW_VERSION} and cut a GitHub Release."
