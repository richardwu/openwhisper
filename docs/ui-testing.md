# Testing the main customer journeys

Use `scripts/test_background.sh` for routine checks without cursor input or window presentation.
The script runs unit tests, the recording pipeline with fixtures, and hidden-window layout checks.
`scripts/test_background.sh --real-models` also runs Apple Speech, cached Moonshine, Nemotron and Parakeet recognizers against recorded audio.
The Moonshine journey sends audio through the app's frame callback and checks live partials, final text, paste output and history persistence.
Missing model caches produce explicit skips in the log; a skip does not verify a recognizer.
The script reuses a Moonshine checkpoint under `.context/models/` when available.
Set `OPENWHISPER_MOONSHINE_MODEL` or `OPENWHISPER_NEMOTRON_MODEL` to use another checkpoint.

The Parakeet regression replays 66 seconds of recorded human speech at microphone speed.
It checks changed live previews, repeated speech, pinned vocabulary, finalization below three seconds,
and main-thread heartbeat gaps below 300 ms. It logs resident memory every 15 seconds;
resident-memory growth alone does not establish a leak because Core ML allocates caches.
A second test checks rapid cancel/restart, late audio, and reuse of the loaded model.

`AppStateTests.testAllStreamingBackendsShareResponsiveFinalizationAndCleanup` loops
over every streaming backend in the selector. It checks success, silence and failure,
the processing phase before decoder completion, ignored hotkey reentry, and final
vocabulary correction before paste/history. This covers future selector additions.
`StreamingTranscriptionTests` checks backend pinning, canceled callbacks, a burst of
1,000 previews, vocabulary snapshots, equivalent results, UI responsiveness, and
stale C++ worker completion. These checks use decoder spies, not every model's weights.

The test host requires both `OPENWHISPER_TEST_MODE=1` and `OPENWHISPER_HEADLESS_TESTS=1` to suppress presentation.
The background script sets both flags and tests that no windows or recording panels become visible.
Normal app launches retain their windows and menu bar item.

Run `scripts/test_ui_e2e.sh` for native click-through tests on a Mac with Xcode and XcodeGen installed.
XCUITest uses an interactive desktop and can move focus and the cursor while running.
Keep these tests on a separate test Mac or within a local macOS VM when the host desktop is in use.
[Apple supports macOS guests on Apple silicon](https://developer.apple.com/documentation/virtualization).
[Tart supports macOS images and SSH](https://tart.run/quick-start/), and its [`--no-graphics` mode](https://github.com/openai/tart/blob/main/Sources/tart/Commands/Run.swift) suppresses the VM window.
VM testing still needs an interactive session inside the guest. It does not establish physical-microphone behavior or performance on the host.

The script regenerates the project and preserves local development signing.
For another signing team, set `OPENWHISPER_DEVELOPMENT_TEAM`.
CI can explicitly set `OPENWHISPER_CODE_SIGN_IDENTITY=-`.
Each run preserves a full log and a uniquely named `.xcresult` under `.build/xcresult/`.
Failed tests attach a screenshot and the Accessibility hierarchy.

## Coverage

| Journey | Assertions |
| --- | --- |
| Navigation | Home, History, Vocabulary and Settings remain reachable; sidebar and footer stay inside the window. |
| Empty Vocabulary | The editor, disabled Add button and sidebar remain visible after visiting other sections. |
| Vocabulary editing | Comma-separated additions, case-insensitive deduplication, lowercase terms, search, no matches, removal, persistence after restart and Delete All. |
| Recording | Start, stop, final text, history entry and footer preview. |
| Copy | Footer and History overwrite a unique clipboard sentinel with the exact transcript. The original clipboard is restored afterward. |
| Recovery | Cancellation, silence, transcription errors and another recording attempt. |
| History deletion | Cancel a deletion, confirm one deletion, then clear the test history. |
| Model settings | Search and select models; reset an unsupported language and restrict the language menu. |
| Startup conditions | Microphone/Accessibility permission banners and model download progress. |

UI tests use unique defaults suites, fixture audio, stub transcription and a paste spy.
They do not edit the user's dictionary or history, access the microphone, download models, or paste into another app.
These tests verify the app's UI and orchestration. They do not establish real-model accuracy or external-app insertion.
Real recognizer tests remain in `Tests/OpenWhisperTranscriptionTests/`.

## Screen-safe layout regression

`VocabularyLayoutTests` hosts the actual `MainWindowView` in hidden windows.
The tests check empty Vocabulary, populated Vocabulary and empty History at 620 × 640 (default), 580 × 420 (minimum) and 700 × 1000 points.
The split pane must fit within the window. These tests never activate a window or move the cursor.

The original failure came from a vertically fixed header in Vocabulary.
During minimum-size calculation, the header wrapped at a tiny proposed width and forced the split pane beyond the visible window.
Checking element existence alone missed the defect because the offscreen controls still existed in Accessibility.

Run the layout regressions with development signing and the headless host:

```sh
xcodegen generate
TEST_RUNNER_OPENWHISPER_TEST_MODE=1 TEST_RUNNER_OPENWHISPER_HEADLESS_TESTS=1 \
xcodebuild test -scheme OpenWhisper -destination 'platform=macOS' \
  -derivedDataPath .build -only-testing:OpenWhisperTests/VocabularyLayoutTests \
  CODE_SIGN_IDENTITY='Apple Development' CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

## Local validation on 2026-10-04

The background profile passed all 57 unit tests and four real-model integration tests, without skips.
The Moonshine journey published 30 partial updates before stop and finalized:
“Hello, this is me testing that OpenWhisper end-to-end tests work properly.”
The tests checked the same final text in history and the paste spy.
Two presentation tests confirmed the host remained prohibited from activation and had no visible windows.

The initial native UI run passed 10 of 11 journeys, including the Vocabulary regression.
The remaining test queried an Alert node for a confirmation that macOS exposed as a Sheet.
The test now uses the captured Sheet structure. That change compiled but has not had a native rerun since testing switched to the background profile.

## Parakeet slowdown diagnosis on 2026-10-05

On an Apple M4 Max with 128 GB RAM, the Debug baseline took 10.76 seconds to finish
the 66-second fixture and blocked the main thread for up to 350 ms. Of 736 live
callbacks, 702 repeated an unchanged transcript. Resident memory changed by only
0.63 MiB between the 30-second sample and finalization.

The wrapper ran the full fuzzy vocabulary matcher on the main thread after every
microphone buffer. Matching 76 words took approximately 149 ms in Debug, while
typical buffers arrived every 85 ms. This created a work backlog as text grew.

The fix captures immutable vocabulary, matches changed previews off the main thread,
and performs final filtering/correction on a worker. Parakeet also drains unused token
timings, clears completed stream state, and waits for canceled work before resetting.
The overlay enters its transcribing phase before waiting for the decoder.

The final fixed replay finished in 0.25 seconds, retained all seven repeated phrases,
and published 34 changed previews with no duplicates. The largest heartbeat gap was
129 ms; memory changed by 0.16 MiB after the 30-second sample. All 69 background
checks passed, including cancellation and reuse of the loaded model. These checks use recorded audio and a paste spy; they do not operate
the microphone or paste into another app.

## Shared streaming policy

`BackendStreamingTranscriptionService` now owns preview correction for all production
streaming decoders. It captures immutable vocabulary at begin, runs one detached
preview worker, skips unchanged raw/corrected text, and buffers only the newest pending
preview. This policy never drops audio frames. Native decoders return raw text;
`TranscriptionService.finalizeTranscription` performs the final correction on a worker.

The router pins the active decoder until completion or cancellation. Session checks
reject old callbacks and worker results. The overlay changes to its spinner and
`Processing...` label before AppState awaits any final work. Contributor requirements
are recorded in [AGENTS.md](../AGENTS.md).

The initial shared-policy run passed 68 unit tests and six recognizer/journey tests
on the same Mac, without skips. Apple Speech, Moonshine Small, Nemotron Speech and
Parakeet Unified used real cached recognizers. The long Parakeet replay finished in
0.24 seconds, had a maximum heartbeat gap of 69 ms, and retained all repeated speech.

The final run passed 69 unit tests and six recognizer/journey tests, without skips.
The lifecycle test covers every streaming backend with decoder spies; real cached
recognizers cover Apple, Parakeet Unified, Moonshine Small and Nemotron Speech.
The hidden overlay test verifies an indeterminate spinner and reads `Processing...`
from the actual render without presenting a window. The 66.444-second Parakeet replay
finished in 0.25 seconds, had a maximum heartbeat gap of 58 ms, and retained all seven
repeated phrases. Resident memory decreased by 43.64 MiB after the 30-second sample.
Results: `.build/xcresult/background-20261005-192522-2284.xcresult`.
