#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

test_targets=(-only-testing:OpenWhisperTests)
case "${1:-}" in
  "") ;;
  --real-models)
    test_targets+=(
      -only-testing:OpenWhisperTranscriptionTests/AppleStreamingTranscriptionTests
      -only-testing:OpenWhisperTranscriptionTests/MoonshineStreamingTranscriptionTests
      -only-testing:OpenWhisperTranscriptionTests/NemotronStreamingTranscriptionTests
      -only-testing:OpenWhisperTranscriptionTests/FluidAudioStreamingTranscriptionTests
      -only-testing:OpenWhisperTranscriptionTests/BackgroundDictationJourneyTests
      -only-testing:OpenWhisperTranscriptionTests/RealTranscriptionTests/testCancelAndRestartUsesFreshBatchSession
    )
    # Forward model overrides to XCTest. Reuse workspace experiment assets.
    if [[ -n "${OPENWHISPER_MOONSHINE_MODEL:-}" ]]; then
      export TEST_RUNNER_OPENWHISPER_MOONSHINE_MODEL="$OPENWHISPER_MOONSHINE_MODEL"
    elif [[ -z "${TEST_RUNNER_OPENWHISPER_MOONSHINE_MODEL:-}" && -f .context/models/moonshine-streaming-small-Q8_0.gguf ]]; then
      export TEST_RUNNER_OPENWHISPER_MOONSHINE_MODEL="$PWD/.context/models/moonshine-streaming-small-Q8_0.gguf"
    fi
    if [[ -n "${OPENWHISPER_NEMOTRON_MODEL:-}" ]]; then
      export TEST_RUNNER_OPENWHISPER_NEMOTRON_MODEL="$OPENWHISPER_NEMOTRON_MODEL"
    fi
    ;;
  *) echo "Usage: $0 [--real-models]" >&2; exit 2 ;;
esac

run_name="background-$(date +%Y%m%d-%H%M%S)-$$"
result_path=".build/xcresult/${run_name}.xcresult"
log_path=".build/xcresult/${run_name}.log"
host_suite="com.openwhisper.test.${run_name}"
mkdir -p .build/xcresult

export TEST_RUNNER_OPENWHISPER_TEST_MODE=1
export TEST_RUNNER_OPENWHISPER_TEST_SCENARIO=launch_ready_state
export TEST_RUNNER_OPENWHISPER_DEFAULTS_SUITE="$host_suite"
export TEST_RUNNER_OPENWHISPER_HEADLESS_TESTS=1
export TEST_RUNNER_OPENWHISPER_DISABLE_HOTKEYS=1
export TEST_RUNNER_OPENWHISPER_DISABLE_SPARKLE=1
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=

# The test host owns this unique domain. Never clear the app's real defaults.
trap 'defaults delete "$host_suite" >/dev/null 2>&1 || true' EXIT

xcodegen generate
echo "==> Running background tests (no window presentation or cursor input)..."
xcodebuild test \
  -project OpenWhisper.xcodeproj \
  -scheme OpenWhisper \
  "${test_targets[@]}" \
  -destination 'platform=macOS' \
  -derivedDataPath .build \
  -parallel-testing-enabled NO \
  -resultBundlePath "$result_path" \
  CODE_SIGN_IDENTITY="${OPENWHISPER_CODE_SIGN_IDENTITY:-Apple Development}" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="${OPENWHISPER_DEVELOPMENT_TEAM:-T2ZTUY8F2X}" \
  2>&1 | tee "$log_path" | tail -40

echo "==> Results at $result_path; full log at $log_path"
if rg -q ' skipped ' "$log_path"; then
  echo "==> Some tests skipped. Check the log for unavailable model assets."
fi
