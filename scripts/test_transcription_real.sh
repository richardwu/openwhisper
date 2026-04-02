#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -z "${OPENWHISPER_MODEL_PATH:-}" ]; then
  echo "Error: OPENWHISPER_MODEL_PATH must be set to a valid ggml model file."
  echo "Example: OPENWHISPER_MODEL_PATH=~/Library/Application\\ Support/OpenWhisper/Models/ggml-base.en.bin $0"
  exit 1
fi

echo "==> Using model: $OPENWHISPER_MODEL_PATH"
echo "==> Regenerating Xcode project..."
xcodegen generate

rm -rf .build/xcresult/transcription-real.xcresult

echo "==> Running real transcription tests..."
xcodebuild test \
  -scheme OpenWhisper \
  -only-testing:OpenWhisperTranscriptionTests \
  -destination 'platform=macOS' \
  -derivedDataPath .build \
  -resultBundlePath .build/xcresult/transcription-real.xcresult \
  OPENWHISPER_MODEL_PATH="$OPENWHISPER_MODEL_PATH" \
  CODE_SIGN_IDENTITY="-" \
  2>&1 | tail -20

echo "==> Transcription tests complete. Results at .build/xcresult/transcription-real.xcresult"
