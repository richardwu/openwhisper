#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Regenerating Xcode project..."
xcodegen generate

rm -rf .build/xcresult/ui-e2e.xcresult

echo "==> Running UI E2E tests..."
xcodebuild test \
  -scheme OpenWhisper \
  -only-testing:OpenWhisperUITests \
  -destination 'platform=macOS' \
  -derivedDataPath .build \
  -resultBundlePath .build/xcresult/ui-e2e.xcresult \
  CODE_SIGN_IDENTITY="-" \
  2>&1 | tail -20

echo "==> UI E2E tests complete. Results at .build/xcresult/ui-e2e.xcresult"
