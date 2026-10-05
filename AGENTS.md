# Contributor instructions

Read [CLAUDE.md](CLAUDE.md) for build, signing, and repository conventions.

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
