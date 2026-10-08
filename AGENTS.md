# Contributor instructions

Read [CLAUDE.md](CLAUDE.md) for build, signing, and repository conventions.

## README screenshots

- Capture the signed production app, named `OpenWhisper`. Do not use the Debug app named `OpenWhisper (Dev)` or edit a screenshot to remove its name.
- Use real production views and check visible text for private data before publishing. Do not present fixture model readiness or permission indicators as production state.
- Save captures under `.context/`, then add the selected images to `docs/images/`.
- Use commit-pinned image URLs in README.md. Present History, Vocabulary, and Settings in one row with a caption that explains the features.

## Streaming transcription

- Keep audio and transcription on the user's Mac.
- Route every production streaming backend through `BackendStreamingTranscriptionService` in `OpenWhisper/Transcription/StreamingTranscriptionService.swift`.
- Decoders publish raw partial text and return raw final text. Do not run vocabulary matching in a decoder callback or on the main actor.
- The shared router snapshots vocabulary once per recording, corrects changed previews on one detached worker, and retains only the newest pending preview. Never apply that dropping policy to audio frames.
- Keep native inference off the main actor. Pin the active decoder through finish/cancel. Reject callbacks from canceled sessions and release session buffers and continuations on completion or failure.
- Set `OverlayState.phase` to `.transcribing` before awaiting decoder completion or final correction. Show the animated spinner and `Processing...` label until completion, silence, or failure.
- Use `TranscriptionService.finalizeTranscription` for final filtering and vocabulary correction before paste/history.
- Run `scripts/test_background.sh --real-models` after changing a streaming backend or this shared path. Verify the all-backend lifecycle test, bounded/changed preview tests, main-actor heartbeat, cancellation/restart, and the long Parakeet replay. Unavailable model skips are not successful hardware checks; report them.
- Prefer background tests and hidden-window rendering. Native UI automation can take over the user's desktop; reserve it for a separate test session or Mac.

## Before merging into main

UI E2E CI runs on pushes to `main`, including merges. PR CI does not run UI E2E tests.

1. Before merging, run `scripts/test_ui_e2e.sh` locally on the exact commit to merge. Use a separate test session or Mac because UI automation controls the desktop.
2. If UI E2E tests fail, fix the failures, push the fixes, run `/babysit`, and rerun `scripts/test_ui_e2e.sh` locally.
3. Repeat until the latest PR CI is green and local UI E2E tests pass on the latest commit. Merge only after both conditions hold. Any additional code change requires another local UI E2E pass.
