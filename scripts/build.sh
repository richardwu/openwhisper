#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build -skipPackageUpdates build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
