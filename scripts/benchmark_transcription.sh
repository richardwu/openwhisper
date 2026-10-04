#!/usr/bin/env bash
# Benchmark the real local decoder through AppState. All audio stays on this Mac.
set -euo pipefail

if [[ $# != 0 && $# != 2 ]]; then
  echo "Usage: $0 [audio-file reference.txt]" >&2
  exit 2
fi
if [[ $# == 2 ]]; then
  for benchmark_input in "$1" "$2"; do
    if [[ ! -f "$benchmark_input" ]]; then
      echo "Missing input: $benchmark_input" >&2
      exit 2
    fi
  done
  benchmark_audio="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  benchmark_reference="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
fi
cd "$(dirname "$0")/.."

benchmark_root="$PWD/.context"
mkdir -p "$benchmark_root"
benchmark_run="$(date -u +%Y%m%dT%H%M%SZ)-$$"
benchmark_report="$benchmark_root/transcription-benchmark-$benchmark_run.json"
benchmark_log="$benchmark_root/transcription-benchmark-$benchmark_run.log"
benchmark_result="$benchmark_root/transcription-benchmark-$benchmark_run.xcresult"
benchmark_model="${OPENWHISPER_MODEL_PATH:-$HOME/Library/Application Support/OpenWhisper/Models/ggml-small-q5_1.bin}"
if [[ ! -f "$benchmark_model" ]]; then
  echo "Set OPENWHISPER_MODEL_PATH to an existing compatible ggml model file." >&2
  exit 2
fi
benchmark_model="$(cd "$(dirname "$benchmark_model")" && pwd)/$(basename "$benchmark_model")"

# xcodebuild strips TEST_RUNNER_ before passing these variables to the test host.
export TEST_RUNNER_OPENWHISPER_TEST_MODE=1
export TEST_RUNNER_OPENWHISPER_DISABLE_SPARKLE=1
export TEST_RUNNER_OPENWHISPER_DISABLE_HOTKEYS=1
export TEST_RUNNER_OPENWHISPER_BENCHMARK=1
export TEST_RUNNER_OPENWHISPER_MODEL_PATH="$benchmark_model"
export TEST_RUNNER_OPENWHISPER_BENCHMARK_REPORT="$benchmark_report"
export TEST_RUNNER_OPENWHISPER_BENCHMARK_REPETITIONS="${OPENWHISPER_BENCHMARK_REPETITIONS:-3}"
if [[ $# == 2 ]]; then
  export TEST_RUNNER_OPENWHISPER_BENCHMARK_AUDIO="$benchmark_audio"
  export TEST_RUNNER_OPENWHISPER_BENCHMARK_REFERENCE="$benchmark_reference"
else
  unset TEST_RUNNER_OPENWHISPER_BENCHMARK_AUDIO TEST_RUNNER_OPENWHISPER_BENCHMARK_REFERENCE
fi
if [[ -n "${OPENWHISPER_BENCHMARK_MAX_WER:-}" ]]; then
  export TEST_RUNNER_OPENWHISPER_BENCHMARK_MAX_WER="$OPENWHISPER_BENCHMARK_MAX_WER"
fi
if [[ -n "${OPENWHISPER_VOCABULARY_PROMPT:-}" ]]; then
  benchmark_vocabulary_report="$benchmark_root/vocabulary-benchmark-$benchmark_run.json"
  export TEST_RUNNER_OPENWHISPER_VOCABULARY_BENCHMARK=1
  export TEST_RUNNER_OPENWHISPER_VOCABULARY_PROMPT="$OPENWHISPER_VOCABULARY_PROMPT"
  export TEST_RUNNER_OPENWHISPER_VOCABULARY_REPORT="$benchmark_vocabulary_report"
else
  unset TEST_RUNNER_OPENWHISPER_VOCABULARY_BENCHMARK TEST_RUNNER_OPENWHISPER_VOCABULARY_PROMPT TEST_RUNNER_OPENWHISPER_VOCABULARY_REPORT
fi

xcodegen generate > "$benchmark_log" 2>&1
echo "Running local transcription benchmark. Build and test log: $benchmark_log"
if ! xcodebuild test \
  -scheme OpenWhisper \
  -only-testing:OpenWhisperTranscriptionTests/TranscriptionBenchmarkTests \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath "$benchmark_root/transcription-build" \
  -clonedSourcePackagesDirPath "$benchmark_root/SourcePackages" \
  -resultBundlePath "$benchmark_result" \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X \
  >> "$benchmark_log" 2>&1; then
  tail -60 "$benchmark_log" >&2
  exit 1
fi

# A skipped or undiscovered benchmark must not look like a successful experiment.
if [[ ! -s "$benchmark_report" ]]; then
  echo "The tests produced no benchmark report. Inspect $benchmark_log" >&2
  exit 1
fi
echo "Report: $benchmark_report"
echo "XCTest results: $benchmark_result"
if [[ -n "${benchmark_vocabulary_report:-}" ]]; then
  if [[ ! -s "$benchmark_vocabulary_report" ]]; then
    echo "The tests produced no vocabulary report. Inspect $benchmark_log" >&2
    exit 1
  fi
  echo "Vocabulary report: $benchmark_vocabulary_report"
fi
