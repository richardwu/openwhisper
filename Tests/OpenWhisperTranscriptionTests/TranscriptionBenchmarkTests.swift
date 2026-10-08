import AVFoundation
import XCTest
@testable import OpenWhisper

/// Opt-in benchmarks use the real decoder and the actual AppState recording flow.
/// PasteService is a spy: these tests do not verify microphone capture or OS text insertion.
@MainActor
final class TranscriptionBenchmarkTests: XCTestCase {
    func testCurrentDecoderVocabularyHints() async throws {
        let environment = ProcessInfo.processInfo.environment
        func setting(_ name: String) -> String? { environment[name] ?? environment["TEST_RUNNER_" + name] }
        guard setting("OPENWHISPER_VOCABULARY_BENCHMARK") == "1" else {
            throw XCTSkip("Set OPENWHISPER_VOCABULARY_BENCHMARK=1 to compare local vocabulary hints")
        }
        guard let modelPath = setting("OPENWHISPER_MODEL_PATH"), !modelPath.isEmpty,
              FileManager.default.fileExists(atPath: modelPath),
              let prompt = setting("OPENWHISPER_VOCABULARY_PROMPT"), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let reportPath = setting("OPENWHISPER_VOCABULARY_REPORT"), !reportPath.isEmpty else {
            throw BenchmarkError.invalidConfiguration("Vocabulary benchmark requires an existing OPENWHISPER_MODEL_PATH, OPENWHISPER_VOCABULARY_PROMPT, and OPENWHISPER_VOCABULARY_REPORT")
        }
        let modelURL = URL(fileURLWithPath: modelPath).standardizedFileURL
        let bundle = Bundle(for: type(of: self))
        let manifestURL = try XCTUnwrap(bundle.url(forResource: "transcripts", withExtension: "json", subdirectory: "Fixtures"))
        let manifest = try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: manifestURL))
        let externalAudioPath = setting("OPENWHISPER_BENCHMARK_AUDIO")
        let externalReferencePath = setting("OPENWHISPER_BENCHMARK_REFERENCE")
        let hasExternalSpeech = externalAudioPath != nil || externalReferencePath != nil
        var fixtures: [(file: String, audioURL: URL, reference: String)] = []
        if hasExternalSpeech {
            guard let audioPath = externalAudioPath, !audioPath.isEmpty,
                  let referencePath = externalReferencePath, !referencePath.isEmpty else {
                throw BenchmarkError.invalidConfiguration("External vocabulary speech requires paired OPENWHISPER_BENCHMARK_AUDIO and OPENWHISPER_BENCHMARK_REFERENCE files")
            }
            let audioURL = URL(fileURLWithPath: audioPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                throw BenchmarkError.invalidConfiguration("External vocabulary audio does not exist: \(audioURL.path)")
            }
            let reference = try String(contentsOfFile: referencePath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !BenchmarkWordErrorScore.words(reference).isEmpty else {
                throw BenchmarkError.invalidConfiguration("External vocabulary speech requires a nonempty reference transcript")
            }
            fixtures.append((audioURL.lastPathComponent, audioURL, reference))
        }
        for fixture in manifest.fixtures {
            if hasExternalSpeech && !BenchmarkWordErrorScore.words(fixture.expected).isEmpty { continue }
            let filename = fixture.file as NSString
            let audioURL = try XCTUnwrap(bundle.url(
                forResource: filename.deletingPathExtension, withExtension: filename.pathExtension, subdirectory: "Fixtures/Audio"
            ))
            fixtures.append((fixture.file, audioURL, fixture.expected))
        }
        var runs: [VocabularyBenchmarkRun] = []
        for fixture in fixtures {
            let samples = try loadSamples(fixture.audioURL)
            guard !samples.isEmpty else { throw BenchmarkError.invalidConfiguration("No samples in \(fixture.file)") }
            for promptEnabled in [false, true] {
                let service = TranscriptionService(
                    mode: .live,
                    vocabularyStore: promptEnabled ? VocabularyStore() : nil
                )
                let started = DispatchTime.now().uptimeNanoseconds
                let text = try await service.transcribe(
                    audioFrames: samples, modelURL: modelURL, initialPrompt: promptEnabled ? prompt : nil
                )
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
                let isSpeech = !BenchmarkWordErrorScore.words(fixture.reference).isEmpty
                let wordCount = BenchmarkWordErrorScore.words(text).count
                runs.append(VocabularyBenchmarkRun(
                    fixtureFile: fixture.file, audioPath: fixture.audioURL.path,
                    audioDurationSeconds: Double(samples.count) / 16000,
                    promptEnabled: promptEnabled, elapsedSeconds: elapsed, transcript: text,
                    transcriptWordCount: wordCount, reference: fixture.reference,
                    score: isSpeech ? BenchmarkWordErrorScore(reference: fixture.reference, hypothesis: text) : nil,
                    nonSpeechFalsePositive: isSpeech ? nil : wordCount > 0
                ))
            }
        }
        let report = VocabularyBenchmarkReport(
            modelFilename: modelURL.lastPathComponent, modelPath: modelURL.path, prompt: prompt,
            coverage: "Direct live TranscriptionService with fresh model instances, prompt off/on. Prompt-on runs use the supplied local vocabulary hint; AppState runs use the shared bundled VocabularyStore. Outputs are filtered by TranscriptionService. WER lowercases letters/numbers and treats other characters as word separators; no improvement is assumed.",
            runs: runs
        )
        let reportURL = URL(fileURLWithPath: reportPath)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        print("VOCABULARY_BENCHMARK report=\(reportURL.path) model=\(modelURL.lastPathComponent) runs=\(runs.count)")
    }

    func testRealAudioRecordingFlowBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        func setting(_ name: String) -> String? {
            environment[name] ?? environment["TEST_RUNNER_" + name]
        }

        guard setting("OPENWHISPER_BENCHMARK") == "1" else {
            throw XCTSkip("Set OPENWHISPER_BENCHMARK=1 to run the real-model benchmark")
        }
        guard let modelPath = setting("OPENWHISPER_MODEL_PATH"), !modelPath.isEmpty else {
            throw BenchmarkError.invalidConfiguration("OPENWHISPER_MODEL_PATH is required for an enabled benchmark")
        }
        let modelURL = URL(fileURLWithPath: modelPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw BenchmarkError.invalidConfiguration("Model does not exist: \(modelURL.path)")
        }

        let repetitions: Int
        if let configured = setting("OPENWHISPER_BENCHMARK_REPETITIONS") {
            guard let count = Int(configured), (1...10).contains(count) else {
                throw BenchmarkError.invalidConfiguration("OPENWHISPER_BENCHMARK_REPETITIONS must be an integer from 1 to 10")
            }
            repetitions = count
        } else {
            repetitions = 3
        }
        let maximumWordErrorRate: Double?
        if let configured = setting("OPENWHISPER_BENCHMARK_MAX_WER") {
            guard let maximum = Double(configured), maximum.isFinite, maximum >= 0 else {
                throw BenchmarkError.invalidConfiguration("OPENWHISPER_BENCHMARK_MAX_WER must be a finite, nonnegative number")
            }
            maximumWordErrorRate = maximum
        } else {
            maximumWordErrorRate = nil
        }

        let audioURL: URL
        let reference: String
        if let audioPath = setting("OPENWHISPER_BENCHMARK_AUDIO") {
            audioURL = URL(fileURLWithPath: audioPath).standardizedFileURL
            guard let referencePath = setting("OPENWHISPER_BENCHMARK_REFERENCE"), !referencePath.isEmpty else {
                throw BenchmarkError.invalidConfiguration("External audio requires OPENWHISPER_BENCHMARK_REFERENCE, a UTF-8 reference text file")
            }
            reference = try String(contentsOfFile: referencePath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            guard setting("OPENWHISPER_BENCHMARK_REFERENCE") == nil else {
                throw BenchmarkError.invalidConfiguration("OPENWHISPER_BENCHMARK_REFERENCE requires OPENWHISPER_BENCHMARK_AUDIO")
            }
            let bundle = Bundle(for: type(of: self))
            guard let bundledAudio = bundle.url(forResource: "english-e2e-test-1", withExtension: "m4a", subdirectory: "Fixtures/Audio"),
                  let manifestURL = bundle.url(forResource: "transcripts", withExtension: "json", subdirectory: "Fixtures") else {
                throw BenchmarkError.invalidConfiguration("Bundled benchmark audio or transcripts.json is missing")
            }
            let manifest = try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: manifestURL))
            guard let fixture = manifest.fixtures.first(where: { $0.file == bundledAudio.lastPathComponent }) else {
                throw BenchmarkError.invalidConfiguration("The benchmark audio has no reference in transcripts.json")
            }
            audioURL = bundledAudio
            reference = fixture.expected
        }
        guard !BenchmarkWordErrorScore.words(reference).isEmpty else {
            throw BenchmarkError.invalidConfiguration("The speech benchmark requires a nonempty reference transcript")
        }

        let samples = try loadSamples(audioURL)
        guard !samples.isEmpty else {
            throw BenchmarkError.invalidConfiguration("Benchmark audio contains no samples")
        }
        var runs: [BenchmarkRun] = []
        for index in 1...repetitions {
            runs.append(try await runPipeline(
                service: TranscriptionService(mode: .live), samples: samples,
                modelURL: modelURL, reference: reference, phase: "cold", index: index
            ))
        }

        let warmService = TranscriptionService(mode: .live)
        _ = try await runPipeline(
            service: warmService, samples: samples, modelURL: modelURL,
            reference: reference, phase: "warmup", index: 0
        )
        for index in 1...repetitions {
            runs.append(try await runPipeline(
                service: warmService, samples: samples, modelURL: modelURL,
                reference: reference, phase: "warm", index: index
            ))
        }

        let workspaceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reportURL = setting("OPENWHISPER_BENCHMARK_REPORT").map { URL(fileURLWithPath: $0) }
            ?? workspaceURL.appendingPathComponent(".context/transcription-benchmark.json")
        let report = BenchmarkReport(
            schemaVersion: 1, generatedAt: ISO8601DateFormatter().string(from: Date()),
            modelFilename: modelURL.lastPathComponent, modelPath: modelURL.path,
            audioPath: audioURL.path, sampleRate: 16000,
            audioDurationSeconds: Double(samples.count) / 16000,
            reference: reference, maximumWordErrorRate: maximumWordErrorRate,
            normalization: "Lowercase Unicode letters and numbers; every other character separates words. No number expansion or spelling correction.",
            timing: "pipeline_completion_seconds measures stopRecording through awaited AppState completion. It includes model load for cold runs, decoding, history, spy paste, and overlay finalization. It is an upper bound for spy paste latency, not OS insertion latency. Cold means a new decoder instance; filesystem caches are not cleared.",
            runs: runs
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        print("BENCHMARK report=\(reportURL.path) model=\(modelURL.lastPathComponent) audio_seconds=\(String(format: "%.3f", report.audioDurationSeconds))")
        for run in runs {
            print("BENCHMARK phase=\(run.phase) run=\(run.index) pipeline_completion_seconds=\(String(format: "%.3f", run.pipelineCompletionSeconds)) wer=\(String(format: "%.4f", run.score.wordErrorRate ?? 0)) S=\(run.score.substitutions) D=\(run.score.deletions) I=\(run.score.insertions)")
            if let maximumWordErrorRate, let wordErrorRate = run.score.wordErrorRate {
                XCTAssertLessThanOrEqual(
                    wordErrorRate, maximumWordErrorRate,
                    "\(run.phase) run \(run.index) exceeded the WER gate; inspect \(reportURL.path)"
                )
            }
        }
    }

    private func runPipeline(
        service: TranscriptionService, samples: [Float], modelURL: URL,
        reference: String, phase: String, index: Int
    ) async throws -> BenchmarkRun {
        let suiteName = "com.openwhisper.benchmark.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw BenchmarkError.invalidConfiguration("Could not create isolated benchmark defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(environment: AppEnvironment(
            audioRecorder: AudioRecorder(mode: .fixture(samples: samples)),
            streamingTranscriptionService: nil,
            transcriptionService: service,
            pasteService: PasteService(mode: .spy),
            modelManager: ModelManager(mode: .fixedPath(modelURL), defaults: defaults),
            permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
            historyStore: HistoryStore(defaults: defaults),
            launchConfig: LaunchConfiguration(
                isTestMode: true, testScenario: nil, defaultsSuiteName: suiteName,
                disableSparkle: true, disableHotkeys: true, modelPath: modelURL.path
            )
        ))

        await state.toggleRecording()
        guard state.isRecording else {
            throw BenchmarkError.pipelineFailure("Recording did not start: \(state.statusMessage)")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        await state.toggleRecording()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        guard state.pasteService.pastedTexts.count == 1,
              let hypothesis = state.pasteService.pastedTexts.first,
              !BenchmarkWordErrorScore.words(hypothesis).isEmpty else {
            throw BenchmarkError.pipelineFailure("Expected one nonempty spy paste: \(state.statusMessage)")
        }
        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertEqual(state.historyStore.entries.count, 1)
        XCTAssertEqual(state.historyStore.entries.first?.text, hypothesis)
        XCTAssertTrue(state.statusMessage.hasPrefix("Pasted:"))
        XCTAssertEqual(state.overlayState.phase, .hidden)
        return BenchmarkRun(
            phase: phase, index: index, pipelineCompletionSeconds: elapsed,
            hypothesis: hypothesis, score: BenchmarkWordErrorScore(reference: reference, hypothesis: hypothesis)
        )
    }

    /// AVFoundation conversion matches the decoder's 16 kHz mono Float32 input.
    private func loadSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw BenchmarkError.invalidConfiguration("Could not create the benchmark audio converter")
        }
        var samples: [Float] = []
        var readError: Error?
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                let remaining = file.length - file.framePosition
                guard remaining > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let inputFrames = AVAudioFrameCount(min(remaining, AVAudioFramePosition(max(1, requested))))
                guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inputFrames) else {
                    readError = BenchmarkError.invalidConfiguration("Could not allocate the benchmark input buffer")
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input)
                    inputStatus.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            guard status != .error, let channel = output.floatChannelData?[0] else {
                throw BenchmarkError.invalidConfiguration("Audio conversion failed")
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            if status == .endOfStream { return samples }
        }
    }

    func testAudioConverterDrainsAllSamplesAtEndOfFile() throws {
        let bundle = Bundle(for: type(of: self))
        for (name, extensionName, expectedFrames) in [
            ("english-e2e-test-1", "m4a", 151872),
            ("silence", "wav", 32000),
            ("background-noise", "wav", 32000),
        ] {
            let url = try XCTUnwrap(bundle.url(
                forResource: name, withExtension: extensionName, subdirectory: "Fixtures/Audio"
            ))
            let samples = try loadSamples(url)
            XCTAssertLessThanOrEqual(abs(samples.count - expectedFrames), 1, "Incomplete conversion for \(name)")
        }
    }

    func testWordErrorScoreCountsSubstitutionsDeletionsAndInsertions() {
        let substitution = BenchmarkWordErrorScore(reference: "one two", hypothesis: "one three")
        XCTAssertEqual(substitution.substitutions, 1)
        XCTAssertEqual(substitution.deletions, 0)
        XCTAssertEqual(substitution.insertions, 0)
        XCTAssertEqual(substitution.wordErrorRate, 0.5)
        let deletion = BenchmarkWordErrorScore(reference: "one two", hypothesis: "one")
        XCTAssertEqual(deletion.deletions, 1)
        let insertion = BenchmarkWordErrorScore(reference: "one", hypothesis: "one two three")
        XCTAssertEqual(insertion.insertions, 2)
        XCTAssertEqual(insertion.wordErrorRate, 2.0, "WER can exceed 100 percent")
    }

    func testWordErrorScoreNormalizesCasePunctuationAndKeepsRepeatedWords() {
        let matching = BenchmarkWordErrorScore(reference: "Hello, END-to-end!", hypothesis: "hello end to end")
        XCTAssertEqual(matching.totalErrors, 0)
        let duplicate = BenchmarkWordErrorScore(reference: "word word", hypothesis: "word")
        XCTAssertEqual(duplicate.deletions, 1)
        let emptyReference = BenchmarkWordErrorScore(reference: "", hypothesis: "extra")
        XCTAssertEqual(emptyReference.insertions, 1)
        XCTAssertNil(emptyReference.wordErrorRate, "WER is undefined when the reference has no words")
    }
}

private enum BenchmarkError: Error {
    case invalidConfiguration(String)
    case pipelineFailure(String)
}

private struct FixtureManifest: Decodable {
    struct Fixture: Decodable { let file: String; let expected: String }
    let fixtures: [Fixture]
}

private struct BenchmarkReport: Encodable {
    let schemaVersion: Int
    let generatedAt: String
    let modelFilename: String
    let modelPath: String
    let audioPath: String
    let sampleRate: Int
    let audioDurationSeconds: Double
    let reference: String
    let maximumWordErrorRate: Double?
    let normalization: String
    let timing: String
    let runs: [BenchmarkRun]
}

private struct BenchmarkRun: Encodable {
    let phase: String
    let index: Int
    let pipelineCompletionSeconds: Double
    let hypothesis: String
    let score: BenchmarkWordErrorScore
}

private struct VocabularyBenchmarkReport: Encodable {
    let modelFilename: String
    let modelPath: String
    let prompt: String
    let coverage: String
    let runs: [VocabularyBenchmarkRun]
}

private struct VocabularyBenchmarkRun: Encodable {
    let fixtureFile: String
    let audioPath: String
    let audioDurationSeconds: Double
    let promptEnabled: Bool
    let elapsedSeconds: Double
    let transcript: String
    let transcriptWordCount: Int
    let reference: String
    let score: BenchmarkWordErrorScore?
    let nonSpeechFalsePositive: Bool?
}

/// Levenshtein alignment with deterministic substitution → deletion → insertion tie breaking.
private struct BenchmarkWordErrorScore: Encodable {
    let referenceWordCount: Int
    let hypothesisWordCount: Int
    let substitutions: Int
    let deletions: Int
    let insertions: Int
    let totalErrors: Int
    let wordErrorRate: Double?

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    init(reference: String, hypothesis: String) {
        let expected = Self.words(reference)
        let actual = Self.words(hypothesis)
        var costs = Array(repeating: Array(repeating: 0, count: actual.count + 1), count: expected.count + 1)
        for row in 0...expected.count { costs[row][0] = row }
        for column in 0...actual.count { costs[0][column] = column }
        if !expected.isEmpty && !actual.isEmpty {
            for row in 1...expected.count {
                for column in 1...actual.count {
                    let mismatch = expected[row - 1] == actual[column - 1] ? 0 : 1
                    costs[row][column] = min(
                        costs[row - 1][column - 1] + mismatch,
                        min(costs[row - 1][column] + 1, costs[row][column - 1] + 1)
                    )
                }
            }
        }
        var row = expected.count
        var column = actual.count
        var substitutionCount = 0
        var deletionCount = 0
        var insertionCount = 0
        while row > 0 || column > 0 {
            if row > 0 && column > 0 && expected[row - 1] == actual[column - 1] {
                row -= 1
                column -= 1
            } else if row > 0 && column > 0 && costs[row][column] == costs[row - 1][column - 1] + 1 {
                substitutionCount += 1
                row -= 1
                column -= 1
            } else if row > 0 && costs[row][column] == costs[row - 1][column] + 1 {
                deletionCount += 1
                row -= 1
            } else {
                insertionCount += 1
                column -= 1
            }
        }
        referenceWordCount = expected.count
        hypothesisWordCount = actual.count
        substitutions = substitutionCount
        deletions = deletionCount
        insertions = insertionCount
        totalErrors = substitutionCount + deletionCount + insertionCount
        wordErrorRate = expected.isEmpty ? nil : Double(totalErrors) / Double(expected.count)
    }
}
