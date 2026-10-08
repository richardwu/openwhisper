#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Regenerating Xcode project..."
xcodegen generate

run_name="ui-e2e-$(date +%Y%m%d-%H%M%S)"
result_path=".build/xcresult/${run_name}.xcresult"
log_path=".build/xcresult/${run_name}.log"
mkdir -p .build/xcresult

# Preserve local permissions across builds. CI can explicitly override these.
signing_identity="${OPENWHISPER_CODE_SIGN_IDENTITY:-Apple Development}"
development_team="${OPENWHISPER_DEVELOPMENT_TEAM:-T2ZTUY8F2X}"

# Public package dependencies do not need GitHub account credentials.
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=

echo "==> Running UI E2E tests..."
xcodebuild test \
  -project OpenWhisper.xcodeproj \
  -scheme OpenWhisper \
  -only-testing:OpenWhisperUITests \
  -destination 'platform=macOS' \
  -derivedDataPath .build \
  -resultBundlePath "$result_path" \
  CODE_SIGN_IDENTITY="$signing_identity" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$development_team" \
  2>&1 | tee "$log_path" | tail -40

echo "==> UI E2E tests complete. Results at $result_path; full log at $log_path"
