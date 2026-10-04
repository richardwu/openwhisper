# Local streaming dictation: investigation and implementation plan

Investigated on October 2, 2026. Requirement: audio and transcription remain on the Mac.

## Recommendation

Change the app from **record → stop → decode everything → paste** to **record and decode concurrently → stop → finalize the remaining audio → paste once**.

Compare Apple `SpeechAnalyzer` / `SpeechTranscriber`, WhisperKit with a larger model and vocabulary prompts, and FluidAudio's vocabulary-capable streaming backend. Apple replay already demonstrated the desired stop behavior on this Mac, but its newer recognizer has no documented personal-vocabulary mechanism. The user's added vocabulary requirement therefore matters when selecting the backend. Keep the existing local backend available during evaluation and preserve macOS 14 support.

Do not choose a model from one short recording. The short fixture establishes feasibility, not general dictation quality. A long, human-corrected recording is the next quality input. The user should not need to maintain a word list: discover spellings from approved projects, current context and normal corrections. Apple is the measured latency candidate; WhisperKit and FluidAudio need direct comparison with automatically selected vocabulary.

The investigation adds benchmark tools and a standalone streaming experiment. It does **not** change the production recorder or ship a streaming backend.

## What causes the current behavior

| Concern | Observed implementation | Consequence |
| --- | --- | --- |
| Work starts after stop | `AudioRecorder` accumulates samples; `AppState.stopRecordingAndTranscribe()` then calls the decoder | All inference remains after the user's stop action |
| Model and decoding | Default multilingual `ggml-small-q5_1.bin`; choices base, quantized small, quantized medium; greedy decoding | Model capacity, quantization and decoding are quality variables |
| Runtime | SwiftWhisper `fast`, revision `deb1cb6`; vendored whisper.cpp commit `95b02d76` from May 2023 | The app does not configure modern Metal acceleration |
| Acceleration in this run | Runtime attempted a sibling `ggml-small-encoder.mlmodelc`, which was absent | The measured app fell back from Core ML |
| Initialization | `TranscriptionService` constructs the decoder on the main actor after stop | First dictation pays model loading cost and may stall the UI |
| Context | `initialPrompt` is supported but `AppState` supplies none | Technical names have no vocabulary hints |
| Filtering | The service strips parenthetical tags and several entire phrases | Cleaned output can lose legitimate words; quality includes postprocessing |

Sources in this repository: [AudioRecorder](../OpenWhisper/Audio/AudioRecorder.swift), [AppState](../OpenWhisper/AppState.swift), [TranscriptionService](../OpenWhisper/Transcription/TranscriptionService.swift), [ModelManager](../OpenWhisper/Transcription/ModelManager.swift), and [project.yml](../project.yml).

The post-stop delay is an architectural fact. Smaller models and quantization are plausible contributors to errors, but their contribution has not been isolated. Faster execution alone does not improve recognition. Streaming also does not automatically improve recognition; shorter context can reduce accuracy.

Conductor's behavior does not establish its private model or provider. Public cloud APIs can accept live audio, but cloud backends are outside this plan because of the local-only requirement. Changing a file-upload endpoint to stream its response would still leave capture before inference.

## Local candidates

| Candidate | Audio processing | Fit and limitation |
| --- | --- | --- |
| Apple SpeechTranscriber | Concurrent input and result sequences; volatile text followed by final segments | First candidate on this Mac; requires macOS 26, supported hardware and locale assets. Query capabilities at runtime. Apple manages model updates, so record OS/build with results. |
| WhisperKit with large-v3 or large-v3 turbo | Incremental application processing through repeated decoding of unconfirmed audio | Candidate for macOS 14 and broader Whisper language coverage. Benchmark both quality and memory; turbo is a speed/quality choice. This is not a cache-aware native streaming model. |
| FluidAudio Nemotron streaming | Native cache-aware streaming with selectable context/chunk latency | Evaluate the multilingual manager when vocabulary matters: v0.17.5 exposes decode-time custom vocabulary biasing. The English and multilingual managers have different capabilities; pin and test the exact variant. Requires Core ML assets and Swift 6 tooling. |
| FluidAudio Parakeet TDT v3 / Ultra | Overlapping sliding-window decoding | Local candidate with a narrower language set than Whisper. Its CTC vocabulary rescorer uses additional acoustic-model evidence. Do not conflate TDT windowing with Parakeet EOU's native streaming architecture. |
| Modern whisper.cpp with Metal | Faster batch inference; overlapping windows can be scheduled during capture | Measured runtime improvement on the same small model. Window boundaries, repeated words and final revisions still need application logic. |

Primary documentation: [Apple's API and sample](https://developer.apple.com/videos/play/wwdc2025/277/), [Apple fastResults](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption/fastresults), [WhisperKit source and requirements](https://github.com/argmaxinc/argmax-oss-swift), [WhisperKit stream implementation](https://github.com/argmaxinc/argmax-oss-swift/blob/main/Sources/WhisperKit/Core/Audio/AudioStreamTranscriber.swift), [FluidAudio models](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md), [FluidAudio Nemotron](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Nemotron.md), and [whisper.cpp](https://github.com/ggml-org/whisper.cpp).

Simply adding a large-v3 model URL to the current enum is insufficient. The vendored runtime predates large-v3; use a runtime that supports the selected weights.

## Experiments and evidence

Machine: Apple M4 Max, 16 CPU cores, 128 GB RAM, macOS 26.6.2, arm64. Xcode supplies Swift 6.2 and the macOS 26 SDK. These timings do not predict performance on smaller Macs.

Input: the existing human fixture `Tests/Fixtures/Audio/english-e2e-test-1.m4a`, 9.492 seconds, mono 48 kHz AAC. Its checked-in reference is: “Hello, this is me testing that OpenWhisper end-to-end tests work properly.”

### Current app

The existing 19 unit tests and four real transcription tests passed with no skips. Runtime logs confirmed the missing Core ML encoder. The old full-pipeline test transcribes first and substitutes a stub for AppState; it does not prove atomic decoder-to-app integration.

The new benchmark instead injects fixture audio and a **live decoder** into the actual AppState. It verifies exactly one spy paste, identical history text, successful status and a hidden overlay. It records cold and warm stop-to-pipeline-completion time and word error rate (WER).

In the first successful benchmark, median completion was 1.382 s with a new decoder and 1.286 s with a reused decoder. All three cold runs had 4 edits / 13 reference words (30.77% WER). Warm runs ranged from 4 to 10 edits and sometimes appended unrelated phrases. This is a short-fixture observation, not a corpus-wide error estimate. Results: `.context/transcription-benchmark-20261003T023928Z-87609.json`.

“Cold” means a new decoder instance, not cleared filesystem caches. Timing starts at stop and ends after AppState completion. It includes history and overlay work and bounds the spy-paste latency. Fixture mode bypasses microphone capture; spy mode bypasses actual OS insertion.

### Modern Whisper runtime

The installed whisper.cpp 1.9.1 CLI used the same `ggml-small-q5_1.bin` model and a converted 16 kHz mono signed-16-bit WAV. Three separate processes per backend gave:

| Runtime | Median process wall time | Median engine time |
| --- | --- | --- |
| Metal | 0.281 s | 170.62 ms |
| CPU, `--no-gpu` | 1.921 s | 1807.35 ms |

All six transcripts were identical. The first GPU process took 0.666 seconds. Caches were not controlled. The CLI decoder configuration differs from the old app, so this comparison isolates acceleration **within the modern CLI**, not the app's exact speedup. It provides no evidence of improved model quality.

Details and reproduction script: `.context/runtime-comparison.md`, `.context/runtime-comparison-results.json`, `.context/runtime-comparison.py`.

### Apple streaming replay

The standalone experiment sends timestamped 200 ms chunks at real-time pace. It uses SpeechTranscriber on-device, not microphone capture or a remote recognition service. It verifies the source read and records converted/sent frame counts. Those counts matched the expected resampling ratio for the tested fixtures. It awaits explicit finalization through the end of input.

In the first normal-mode run, the first partial arrived 4.044 seconds after replay started. The transcript became final 1.556 seconds **before** stop. End-of-input finalization completed 28.4 ms after stop. Removing most trailing silence produced the same final transcript, with 104.5 ms of post-stop finalization. Normal-mode partial output arrived in roughly four-second groups; this remains a preview-latency tradeoff to test.

The final text was: “Hello, this is me testing that open whisper end to end tests work properly.” Brand spelling is not exact. WER must retain that difference rather than silently merging “open whisper” into “OpenWhisper”.

Strict WER was 2 / 13 = 15.38%: one substitution and one insertion from the brand's word segmentation. `fastResults` shortened first-partial time to 3.022 s, with the same final text. Silence and noise produced empty output. A 113.904 s replay of 12 copies sent all 1,822,464 converted samples, preserved all 12 sentences, and drained in 33.4 ms after stop. Its 24 / 156 edits were the same brand differences repeated 12 times. This repetition is a continuity test, not a long spontaneous-speech accuracy test.

Reports are stored under `.context/apple-streaming-*.json` with event timestamps and logs. These measurements establish local streaming feasibility. They do not establish full production capture-to-paste correctness.

## Automatic vocabulary without a cloud service

The user does not have a prepared list. Make automatic discovery the normal path. Keep manual pins and exclusions as optional overrides, rather than onboarding requirements. Context selection and correction learning can run on the Mac; neither requires retraining the acoustic model.

For the first usable implementation, keep discovery simple: ship a local bundle of coding and knowledge-work terms, then promote only high-confidence user corrections. Do not require project selection and do not read text near the cursor. Those sources add permission and privacy cost before the bundle and correction path have been measured on the user's recordings.

### How other dictation apps adapt

The public documentation supports two useful mechanisms: collect trusted spellings from the current task, and learn from edits after insertion. It does not establish which private acoustic model makes another app more accurate.

| App | Documented mechanism | Relevant limitation |
| --- | --- | --- |
| Wispr Flow | Reads text near the cursor, visible names/code symbols and editor file names. Auto-add monitors the textbox containing its pasted dictation for corrected spellings. | Its transcription runs in the cloud. Borrow the mechanism, not its deployment model. |
| VoiceInk | Compares inserted text with later edits. Reviews a changed passage with up to three adjacent words per side to identify reusable names and phonetic corrections. | Review uses its separately selected provider; local Ollama can keep review on the Mac. Some apps expose no editable Accessibility text. |
| Superwhisper | Separates recognition hints from exact replacements after recognition. Warns that too many hints can harm accuracy or language detection. | A larger dictionary is not automatically a better prompt. Its selected-text, clipboard and window context can also feed later AI processing; that is distinct from ASR biasing. |

Sources: [Flow context awareness](https://docs.wisprflow.ai/articles/4678293671-Context-Awareness), [Flow correction learning and cloud recognition](https://wisprflow.ai/data-controls), [VoiceInk Auto Learn](https://tryvoiceink.com/docs/auto-learn-dictionary), [Superwhisper vocabulary](https://superwhisper.com/docs/get-started/interface-vocabulary), and [Superwhisper context timing](https://superwhisper.com/docs/common-issues/context).

These are documented product behaviors, not measurements of their accuracy. A periodically refreshed public bundle can add recent public names. Private project names need local context or corrections because a public bundle cannot know them.

### Exact access boundaries

The three automatic sources need separate permission and data paths. They must not be implemented as one broad “read the computer” capability.

**Project files (deferred).** A future version could accept an explicitly approved folder and read only known metadata files and bounded source files below that root. It must never scan the home directory. The first implementation does not ask the user to select a project and does not use project-specific terms.

The repository includes a script experiment that reads this workspace's `project.yml` and `OpenWhisper/` Swift files. That experiment is separate from the app. The current app has no project-folder picker or project detector, and the shipped vocabulary path does not read project files.

**Text near the cursor (deferred).** “Near the cursor” means the focused text element in the frontmost application, not a visual scan of the display. macOS can expose the focused Accessibility element, its selected text/range and, when supported, a bounded substring around that range. The first implementation does not read this context. If later experiments justify it, use `kAXFocusedUIElementAttribute`, selected-text attributes and `kAXStringForRangeParameterizedAttribute`; an app can receive `attributeUnsupported`, `noValue` or `cannotComplete` instead. See Apple's [focused element](https://developer.apple.com/documentation/applicationservices/carbon_accessibility/attributes/kaxfocuseduielementattribute), [attribute access errors](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue) and [range text API](https://developer.apple.com/documentation/applicationservices/carbon_accessibility/parameterized_attributes?language=objc).

The first implementation needs no special cursor control. It uses the bundled vocabulary and correction learner. A future Accessibility context feature would use the normal keyboard focus and caret, not a visual scan; custom editors, terminals, web views and secure fields may expose less or nothing. Secure text fields must remain excluded by their Accessibility subrole; see Apple's [secure-field definition](https://developer.apple.com/documentation/applicationservices/kaxsecuretextfieldsubrole). It should not use screenshots or OCR.

**Corrections.** The learner should observe only the span that OpenWhisper inserted, in the same focused element, for a short period after paste. The proposed sequence is:

1. Before paste, record the target application, Accessibility element identity, insertion range when available and a short-lived session identifier.
2. Paste the final transcript using the existing paste path. Do not capture keyboard events.
3. Subscribe to supported Accessibility value/selection changes, or use a short bounded poll when notifications are unavailable. Read only the inserted span and its immediate replacement, not the entire document.
4. Stop observation when focus changes, another dictation starts or the timeout expires. If the element does not expose a readable value/range, learn nothing.
5. Accept only a small spelling-like change, such as `open whisper` → `OpenWhisper`. Reject large rewrites, changed numbers or facts, edits outside the inserted span and changes that cannot be tied to the insertion.
6. Store the candidate spelling, source scope, count and timestamp. Keep the changed document text, keystrokes and audio out of the vocabulary store. Queue uncertain candidates for review; pins and exclusions override automatic candidates.

This is not a keylogger. A keylogger would capture global key events, including keys typed outside the dictated span. This design captures no key-down or key-up stream. It reacts to a text-field value change and compares a bounded range owned by OpenWhisper. The existing app already posts `Command-V` to paste and temporarily uses the clipboard; that operation inserts text but does not record subsequent keystrokes. Accessibility permission is still sensitive, so the settings UI must state exactly which focused field and bounded range it reads.

### Proposed sources and update rules

| Source | Automatic operation | Scope and lifetime |
| --- | --- | --- |
| Public technical bundle | Ship a versioned pool of canonical tool names and acronyms, with official project/package metadata as spelling evidence and source URLs per entry. Refresh with app releases initially; add optional periodic downloads of the same public file later. | No user-specific request payload. Keep the last verified version for offline use. Select a relevant subset, not the entire bundle. |
| Approved project folders (future) | Extract project/product names, dependency names, imported modules and selected repeated identifiers from known file formats. Regenerate when those files change. | Only after an explicit folder approval. Do not index arbitrary files or search the whole Mac. |
| Current dictation context (future) | Read a bounded region around the caret once per session. Match exact names against the local candidate pool and identify additional likely names/acronyms. | Use the focused Accessibility element when available. Skip secure fields; discard surrounding text after the session. Unsupported fields fall back to the bundled vocabulary. |
| Corrections to our inserted text | Compare the inserted span with later edits in the same text field. Learn high-confidence canonical spellings and usage counts. | Observe only the app's inserted span for a short period. End observation on focus change, another dictation or timeout. Retain the term and evidence, not the full document. |

For a future project-aware version, a repository's metadata could supply `OpenWhisper` and `SwiftWhisper`, while imports could supply `SwiftUI`. The current app ships those terms in its static bundle and does not inspect a repository.

For a future context-aware version, rank explicit pins and confirmed corrections first, then current context/project evidence, then public bundle candidates. The current app ranks learned corrections before the static bundle and snapshots that bounded list at decode start.

Start experiments with 12–20 terms. The backend adapter must enforce its actual tokenizer/context budget; the prototype's character cap is only an extraction bound. Compare larger budgets against quality and false insertions before expanding. Filter to the active language and avoid adding instructions or arbitrary document passages to a vocabulary prompt.

Do **not** learn canonical spellings from uncorrected ASR history. Those outputs contain the very mistakes we want to fix. A transcript correction or trusted project file provides independent spelling evidence. Case and joined-word edits can provide strong canonical-spelling evidence without proving a reusable phonetic alias. Reject ordinary rewrites, changed numbers/facts and edits outside the inserted span. Do not turn a learned name into a global replacement rule.

The first correction observer can use conservative local rules. Queue uncertain edits instead of accepting them. If rules miss useful phonetic corrections, evaluate a small local language model on the changed span later. Run review outside the transcription path; a local LLM is not a prerequisite for the initial feature.

macOS Accessibility offers selected text/ranges and bounded string-for-range queries, although support varies by app. Apple's `NLTagger` can suggest people, places and organizations, but it is not a technical-term dictionary. A synthetic probe on this Mac found only `Nemotron` among nine coding terms and labeled it a person. CamelCase/acronym rules found the other eight but missed lowercase `pgvector` in another sample. Therefore combine structured metadata and spelling patterns; do not rely on named-entity extraction alone. Probe: `.context/nltagger-term-probe.swift` and `.context/nltagger-term-probe.json`.

Sources: [Apple named-entity tagging](https://developer.apple.com/documentation/naturallanguage/identifying-people-places-and-organizations), [selected text](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute), [bounded text ranges](https://developer.apple.com/documentation/applicationservices/kaxstringforrangeparameterizedattribute), and [secure text fields](https://developer.apple.com/documentation/applicationservices/kaxsecuretextfieldsubrole).

### Recognition adapters

Recognition hints and text substitutions are separate operations. For example, a `Claude` hint can help “Ask Claude to review this pull request.” A global `cloud → Claude` substitution would corrupt “The cloud server is down.” Test both sentences with the same vocabulary enabled. Aliases and pronunciation hints should guide recognition or acoustic rescoring rather than force every matching word into the preferred term.

| Backend | Local vocabulary mechanism | Evidence and limit |
| --- | --- | --- |
| Existing SwiftWhisper / modern whisper.cpp | `initialPrompt` containing correctly spelled domain terms | The current service already supports this parameter; AppState does not pass it. A prompt is a hint, not a guarantee or model training. |
| WhisperKit OSS | Decoder prompt tokens/context | Adapt a short lexicon to the chosen tokenizer/decoder. Bound its context length and test prompt contamination, especially on silence. |
| Apple SpeechTranscriber | No documented custom-vocabulary support in SDK 26 | Paired `.general = ["OpenWhisper"]` context experiment produced identical unhinted/hinted output and WER. Do not rely on this context API to personalize the newer recognizer. |
| Apple DictationTranscriber | `AnalysisContext.contextualStrings`; custom local language models through `SFSpeechLanguageModel` | Apple limits contextual strings to 100 phrases across tags, preferably one or two words; unusual terms may need pronunciation support. In a paired replay, the hint fixed `OpenWhisper`, but “end-to-end” remained wrong: WER 4/13 without hints, 2/13 with hints. |
| FluidAudio Parakeet TDT | Custom vocabulary with CTC acoustic rescoring and aliases | Uses additional local CTC weights. Benchmark overhead and false matches. Documentation's published accuracy numbers are not results on this corpus. |
| FluidAudio multilingual Nemotron | `StreamingNemotronMultilingualAsrManager.setCustomVocabulary` and per-token decoder bias | Verified in v0.17.5 after PR #866. This capability is not implied for every Nemotron manager. Public model access was verified by metadata and a weight-file HEAD request, without downloading the large model or claiming measured performance. |

Sources: [Apple contextualStrings](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings), [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber), [FluidAudio vocabulary](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/CustomVocabulary.md), [Nemotron bias implementation in v0.17.5](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Sources/FluidAudio/ASR/Parakeet/Streaming/Nemotron/NemotronVocabularyBias.swift), and [PR #866](https://github.com/FluidInference/FluidAudio/pull/866).

The current Whisper Small experiment already demonstrated a useful local improvement:

| Same human recording, fresh decoder per condition | Final output | Word errors |
| --- | --- | --- |
| No prompt | “Hello, this is me testing that open whisper end-to-end test's work properly.” | 4/13, 30.77% WER |
| `initialPrompt = "OpenWhisper."` | “Hello, this is me testing that OpenWhisper end-to-end tests work properly.” | 0/13, 0% WER |

The same prompt produced empty text on both silence and background noise in this run. These are six real decoder calls, not mocked outputs. Report: `.context/vocabulary-benchmark-20261003T024416Z-431.json`. This proves the mechanism works on one example; broader personal-term accuracy and false-positive behavior require held-out recordings.

Implement hint adapters for only the backend selected by the benchmarks. Keep hints short and relevant. Select context automatically rather than requiring the user to choose vocabulary profiles for each dictation. A correction store does not require training a personal acoustic model or rewriting the entire transcript with a language model.

For WhisperKit, tokenize hints into `promptTokens`, not `prefixTokens`: prefix tokens seed transcript text rather than provide vocabulary context. Keep previous confirmed transcript context separate from the user's preferred spelling list. The first implementation can use the existing Whisper service's `initialPrompt` before replacing its runtime.

Evaluate WER and exact canonical-term accuracy separately. WER normalization removes case and punctuation, so it cannot distinguish `SwiftUI` from `swiftui`. Annotate intended names/acronyms and count both missed preferred terms and preferred terms inserted where none were spoken. Compare hints off/on on held-out speech, ordinary ambiguous words, silence and noise. Keep vocabulary snapshots with the experiment reports, locally.

### Automatic discovery experiment completed

A Python standard-library prototype read `project.yml` and 24 Swift files under `OpenWhisper/`. It extracted 16 terms in 211 prompt characters, including `OpenWhisper`, `SwiftWhisper`, `SwiftUI` and `AVFoundation`. It did not read transcripts, tests, history, personal files or other projects. Each term has source provenance; ranking scores are heuristics, not recognition probabilities.

I supplied the entire generated prompt to the actual current Whisper service. The same 9.492-second human recording changed from 4/13 word errors without hints to 0/13 with discovered hints. Silence and background noise stayed empty in both conditions. All five decoder/benchmark tests passed without skips. Input snapshot: `.context/automatic-vocabulary-input.json`. Decoder report: `.context/vocabulary-benchmark-20261003T032054Z-87817.json`.

This demonstrates automatic project discovery → prompt → real local decoder on one example. It does not validate all 16 names, current-window capture, correction learning or production AppState integration. The parser is intentionally limited to this project's scalar metadata and Swift identifier heuristics; regex literals and interpolation expressions are not parsed. Repeated type names are weaker candidates than project/dependency names. Regeneration picks up changed names and removes deleted file evidence without a persistent cache.

The promoted extractor is `scripts/experiments/discover_vocabulary.py`. Its nine deterministic tests cover explicit source boundaries, symlinks/hidden files, canonical spelling, deduplication, ranking/caps, changed/deleted files, oversized input, nested comments and raw strings. These tests validate extraction behavior, not speech accuracy.

The external-input mode also passed all five benchmark tests without skips. A copy of the same human fixture under `.context/` supplied the speech input; the report confirmed that path and preserved silence/noise checks. Errors again changed from 4/13 to 0/13 with the automatic prompt. This validates the harness's external-file path, not accuracy on a second recording. Report: `.context/vocabulary-benchmark-20261003T032442Z-97767.json`.

## Implementation sequence

### 0. Add automatic vocabulary to the existing decoder first

Add a small injected `VocabularyStore` with a bundled technical pool and learned corrections. Provide source controls and an inspectable learned-term list in settings; do not require the user to write the list. Select a bounded snapshot per recording and pass the formatted initial prompt from AppState to the existing service. Serialize decoding and retain prompt memory until completion. Defer project folders and focused-text context until a golden recording shows that the bundled terms and corrections need more evidence.

Add bounded focused-text context next, with a strict time budget and a cached fallback. Then add an observer for corrections to the app's own inserted span. Validate learning rules independently from recognition and keep uncertain edits out of automatic hints. This order yields an independently useful vocabulary improvement before the streaming migration.

### 1. Freeze the evaluation and compare local backends

Run the current benchmark on short and long human recordings. Compare Apple normal/fast modes, then WhisperKit large-v3 turbo and large-v3 using identical PCM and references. Record model revision/checksum, decoding options, locale, OS/build, sample rate and machine. Report raw model text and final formatted text separately.

Use ordinary timing runs separately from capture/UI stress runs. Exclude downloads and asset preparation from warm dictation latency; report cold preparation separately. Freeze references before tuning. Keep a held-out recording so vocabulary prompts are not evaluated solely on the recording used to create them.

Freeze source-derived vocabulary before decoding each held-out clip. References are for scoring only; never feed reference names into discovery. Record source revisions and vocabulary snapshots alongside model settings. Compare hints disabled, automatic hints and deliberately irrelevant context on identical audio.

Choose the simplest backend that passes recognition, preferred-term and stop-latency gates together. Apple is suitable if the golden recording needs no additional vocabulary bias. If personal terms remain a weakness, prioritize a measured WhisperKit prompt or FluidAudio vocabulary backend. Preserve macOS 14 support with the existing backend initially; migrate the fallback separately after its benchmarks pass.

### 2. Give capture an ordered session interface

Publish owned PCM buffers from the audio tap into one ordered consumer. Include session ID, frame offset, sample rate and channel count. Run conversion/inference away from the main actor. Use a bounded queue with an explicit backlog policy; never silently drop dictated audio.

Keep the microphone and paced fixture replay behind the same input interface. Tests must exercise production conversion and buffer draining, not a separate concatenation implementation. Add a drain acknowledgment before finalization. The current untracked main-actor append tasks can leave the last buffer queued when stop reads the sample array.

Snapshot backend, language and settings at start. Add `preparing`, `recording`, `finishing`, `cancelled` and `failed` states with one active session. Warm models before capture and show asset preparation when needed. Guard the global hotkey during finalization, or explicitly cancel/join the previous session before starting another.

### 3. Stream results and finalize once

Define a small backend interface: prepare/start, append, finish, cancel and transcript events. Use stable segment IDs or audio ranges. Replace volatile text for its range; do not append every preview as new text. Keep committed text and the current preview separately.

For Apple, feed `AnalyzerInput` in `bestAvailableAudioFormat`, read results concurrently, and call `finalizeAndFinishThroughEndOfInput()` after capture drains. For a windowed Whisper backend, use timestamps/overlap and confirm stable words; naive string-prefix trimming fails on repeated words and corrections.

Display previews in the overlay. At stop, finish the unconfirmed tail and construct one final transcript. Save history and paste exactly once. Do not paste volatile text into another app. Define whether focus targets the app active at start or at stop, then test that policy.

On cancellation, cancel capture and inference, await cleanup, and ignore every result from the cancelled session. Apply session checks to delayed overlay dismissal. On inference failure, retain a recoverable local recording only if that behavior is explicitly enabled; never silently switch to a remote service.

### 4. Validate the real application and roll out

Enable the new backend as an explicit local setting initially. Check locale/hardware support and assets before recording. Use a clear local fallback for unsupported configurations. Test installed-release signing and permissions as well as the dev build.

Replace the currently skipped UI record-to-transcribe test. Add a target app or small text receiver under test ownership. Feed audio through the production input interface and use the real backend, AppState, clipboard and CGEvent paste. Assert the receiver's actual text, focus and exactly one insertion. A spy assertion alone is not end-to-end proof.

Run one physical microphone test on the same Mac, with an audio-loopback input if available. Verify sample duration and input format, then recording, live previews, stop, actual insertion and history. Paced file replay provides reproducibility; microphone testing covers device/TCC/capture behavior.

## Runnable tests added now

Run the real current-app baseline with the cached default model:

```bash
scripts/benchmark_transcription.sh
```

Use a specific compatible model and a private golden recording:

```bash
OPENWHISPER_MODEL_PATH='/absolute/path/ggml-small-q5_1.bin' \
  scripts/benchmark_transcription.sh \
  '/absolute/path/golden.m4a' '/absolute/path/golden.txt'
```

`OPENWHISPER_BENCHMARK_REPETITIONS` defaults to 3 cold + 3 warm runs, plus one excluded warmup. Set `OPENWHISPER_BENCHMARK_MAX_WER=0.05` to enforce 5% WER when appropriate; the default records measurements without claiming a quality pass. An enabled benchmark fails for missing inputs, decoder failure, missing paste or invalid state. The wrapper fails if no JSON report is produced.

WER is `(substitutions + deletions + insertions) / reference words`. Normalization lowercases text and splits at characters other than Unicode letters/numbers. Hyphens separate words; numbers are not expanded; repeated words are retained; WER can exceed 100%. The benchmark scores the app's final filtered transcript. Raw decoder output requires a backend event seam in the next implementation.

Run the existing decoder's paired vocabulary experiment alongside the baseline:

```bash
OPENWHISPER_VOCABULARY_PROMPT='OpenWhisper.' scripts/benchmark_transcription.sh
```

This writes a separate vocabulary JSON report. It runs the real service with fresh decoders and the prompt disabled/enabled on speech, silence and noise. It measures the hint mechanism directly; AppState integration of the vocabulary remains part of the implementation plan.

Discover project terms and replay them without supplying a manual list:

```bash
python3 scripts/experiments/test_discover_vocabulary.py
python3 scripts/experiments/discover_vocabulary.py > .context/vocabulary-snapshot.json
OPENWHISPER_VOCABULARY_PROMPT="$(python3 scripts/experiments/discover_vocabulary.py --prompt-only)" \
  scripts/benchmark_transcription.sh
```

To compare hints on a private golden recording, append its audio/reference paths to the final command. External speech replaces bundled speech in the vocabulary comparison; bundled silence/noise remain. Each vocabulary run records its actual audio path. Freeze the vocabulary snapshot before tuning, and keep reference transcripts outside discovery scope.

Replay audio through Apple's on-device streaming API on macOS 26:

```bash
scripts/benchmark_apple_streaming.sh \
  Tests/Fixtures/Audio/english-e2e-test-1.m4a .context/apple-replay.json
```

Optional trailing arguments select chunk duration, a clip limit, `fast`/`normal`, and repetition count. For a stop near speech end, append `0.2 7.4 fast`. For the 113.904 s synthetic load replay, append `0.2 0 normal 12`. The Swift experiment is kept under `scripts/experiments/` and operates independently of the app.

The current-app XCTest wrapper writes JSON, a full log and `.xcresult` under `.context/`. It uses fresh workspace-owned package/build directories and forwards variables with `TEST_RUNNER_`. It preserves development signing and disables hotkeys, Sparkle and automatic model setup for the test host. The Apple wrapper writes the requested JSON and console output; redirect stdout/stderr to retain a log. Speech is never sent to a transcription service. Package or model-asset downloads may require internet; recognition runs on-device.

Validation completed: 23 existing unit/real-model tests passed, followed by all five new benchmark/conversion/scoring tests with vocabulary enabled and no skips. A separate external-file run with a deliberately impossible zero-WER gate failed as expected and preserved its JSON. The promoted Apple wrapper compiled and replayed the 7.4 s tail-cut fixture in fast mode, with 79 ms post-stop drain. These checks cover the tools added here, not an integrated production streaming backend.

## Corpus and acceptance gates

Ask the user for 3–5 minutes of ordinary dictation using their usual microphone. No prepared vocabulary list is required. Discover spelling evidence from approved source folders/context, then annotate the spoken names in the corrected reference for scoring. Include file paths, numbers, natural corrections, repeated words, short/long pauses and 20–30 seconds of continuous speech. Include some unplanned speech, not only a polished read script. Keep the audio and verbatim human-corrected reference private under `.context/golden/` unless the user chooses to publish them.

Retain fillers and spoken repetitions in the verbatim reference. Evaluate optional cleanup separately against an explicitly edited reference. Do not use another model's output as ground truth. Add annotated speech start/end times and a list of critical names/numbers. Add representative languages if multilingual dictation matters.

Suggested adoption gates below are targets to measure, not results already achieved:

| Check | Measurement or assertion |
| --- | --- |
| Recognition | At least 25% relative WER reduction on an error-bearing held-out corpus; target ≤5% for clean speech. If the baseline is already near zero, require no regression instead. Report word counts and each critical name/number. |
| Personal terms | Target ≥95% exact preferred-term accuracy on held-out positive samples; zero preferred terms hallucinated in silence/noise, and no regression on ambiguous ordinary words. Tune bias against false positives rather than guaranteeing every hint appears. |
| Automatic discovery | Use synthetic approved repositories with known names. Assert canonical casing, provenance, ranking, tokenizer budget and exclusions. Update/delete sources; stale candidates must disappear. User exclusions must survive regeneration. No golden references enter discovery. |
| Correction learning | Replay edits to an actual inserted span in a test receiver. Learn a corrected project name; reject rewrites, changed numbers and edits elsewhere. End observation on focus change/timeout/new session. An unavailable Accessibility range must leave dictation working. |
| Context relevance | Replay the same speech with relevant project context, unrelated project context and hints disabled. Score exact names and false insertions separately. Public-bundle updates must not override confirmed user spellings. |
| Vocabulary updates | Test offline startup, unchanged file timestamps and changed metadata. Reject unsupported, malformed, oversized or conflicting bundle updates; preserve the last working bundle. Regeneration and optional local review must not block recording or post-stop insertion. |
| Live feedback | Nonempty partial before stop; target first partial ≤2 s after annotated speech onset. Compare normal versus fast mode explicitly. |
| Finalization | Warm stop-to-final p95 ≤750 ms and stop-to-actual-insertion p95 ≤1 s on representative stop points, including immediate speech-end stops. |
| Length scaling | Test 10 s, 60 s and 3–5 min clips. The unprocessed backlog at stop must stay bounded rather than grow with recording duration. |
| Completeness | Every captured frame reaches the backend once; the last word remains present when stopping without trailing silence. |
| No duplicates | Exactly one final history entry and insertion per successful session; previews never enter the target app. |
| Empty input | Silence and noise cause zero text insertion. Score spurious output separately because WER has no empty-reference denominator. |
| Lifecycle | Cancel during prepare/capture/inference/finalization; rapid sessions; settings changes; old callbacks; input unplug; permission denial; asset failure. No stale paste or hidden active overlay. |
| Local operation | After assets are installed, run with outbound network blocked and verify no remote fallback. Audit dependencies and record any network attempt. |
| Resource use | Record CPU, GPU and peak memory on this M4 Max and at least one lower-memory supported Mac. |

Use at least 20 representative stop events for p95; do not report a three-run maximum as a p95 result. Run several cold starts separately. Include a repetitive long replay only as a load/segmentation test; it is not evidence of spontaneous-dictation accuracy.

Run deterministic lifecycle/event-order tests on every PR. Keep opt-in real-model runs on a Mac with pinned artifacts. Use a macOS 26 machine for Apple tests, with required assets installed; current macOS 15 CI cannot validate this backend. Run a macOS 14 fallback build/check independently. Preserve JSON reports and transcripts for comparison, and fail required jobs rather than accepting skipped real-model tests.

Completion means that a backend passes held-out quality checks and the actual capture-to-text-receiver test. A successful standalone recognizer, test spy or polished demo is an intermediate result.
