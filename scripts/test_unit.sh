#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Regenerating Xcode project..."
xcodegen generate

rm -rf .build/xcresult/unit.xcresult

# Ad-hoc signing is used here for CI compatibility. For local development,
# consider passing CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual
# DEVELOPMENT_TEAM=T2ZTUY8F2X to preserve Microphone/Accessibility permissions
# across rebuilds (see CLAUDE.md).
echo "==> Running unit tests..."
xcodebuild test \
  -scheme OpenWhisper \
  -only-testing:OpenWhisperTests \
  -destination 'platform=macOS' \
  -derivedDataPath .build \
  -resultBundlePath .build/xcresult/unit.xcresult \
  CODE_SIGN_IDENTITY="-" \
  2>&1 | tail -20

echo "==> Unit tests complete. Results at .build/xcresult/unit.xcresult"
