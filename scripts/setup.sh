#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

MAIN_REPO="$(git worktree list --porcelain | head -1 | sed 's/worktree //')"

# Copy SPM package cache from main repo if we don't have one yet
if [ ! -d .build/SourcePackages ] && [ -d "$MAIN_REPO/.build/SourcePackages" ]; then
  echo "==> Copying SPM packages from main repo..."
  mkdir -p .build
  cp -R "$MAIN_REPO/.build/SourcePackages" .build/SourcePackages
fi

xcodegen generate
