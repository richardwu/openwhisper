#!/usr/bin/env bash
# Replay a file into Apple's local SpeechTranscriber at real-time pace.
set -euo pipefail
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 audio-file output.json [chunk_seconds] [limit_seconds|0] [fast|normal] [repeat_count]" >&2
  exit 2
fi
benchmark_script_dir="$(cd "$(dirname "$0")" && pwd)"
benchmark_build="$benchmark_script_dir/../.context/apple-streaming-experiment"
mkdir -p "$(dirname "$benchmark_build")" "$(dirname "$2")"
# Requires Xcode with the macOS 26 SDK and a supported macOS 26 device/locale.
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macosx26.0" \
  "$benchmark_script_dir/experiments/apple_streaming_replay.swift" -o "$benchmark_build"
"$benchmark_build" "$@"
