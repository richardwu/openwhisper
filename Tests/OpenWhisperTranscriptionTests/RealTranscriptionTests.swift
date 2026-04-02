import AVFoundation
import XCTest
@testable import OpenWhisper

/// Integration tests that use the real TranscriptionService with a cached Whisper model.
/// Requires OPENWHISPER_MODEL_PATH environment variable to point to a valid ggml model file.
@MainActor
final class RealTranscriptionTests: XCTestCase {

    private var service: TranscriptionService!
    private var modelURL: URL!

    override func setUp() async throws {
        try await super.setUp()

        let modelPath: String
        if let envPath = ProcessInfo.processInfo.environment["OPENWHISPER_MODEL_PATH"] {
            modelPath = envPath
        } else {
            // Fall back to default model directory — pick the first .bin file found
            let defaultDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/OpenWhisper/Models")
            let contents = (try? FileManager.default.contentsOfDirectory(at: defaultDir, includingPropertiesForKeys: nil)) ?? []
            guard let first = contents.first(where: { $0.pathExtension == "bin" }) else {
                throw XCTSkip("OPENWHISPER_MODEL_PATH not set and no model found in default location — skipping real transcription tests")
            }
            modelPath = first.path
        }

        let url = URL(fileURLWithPath: modelPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Model file not found at \(modelPath)")
        }

        modelURL = url
        service = TranscriptionService(mode: .live)
    }

    // MARK: - Helpers

    private func loadWAVSamples(named name: String) throws -> [Float] {
        return try loadAudioSamples(named: name, ext: "wav")
    }

    private func loadAudioSamples(named name: String, ext: String) throws -> [Float] {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/Audio") else {
            throw XCTSkip("Fixture \(name).\(ext) not found in test bundle")
        }
        return try readAudioFloat32(url: url)
    }

    /// Reads any audio file supported by AVFoundation and returns 16kHz mono Float32 samples.
    private func readAudioFloat32(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let processingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: processingFormat) else {
            throw NSError(domain: "Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
        }

        // Estimate output frame count based on sample rate ratio
        let ratio = 16000.0 / file.processingFormat.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(file.length) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: estimatedFrames) else {
            throw NSError(domain: "Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create output buffer"])
        }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            let inputFrames: AVAudioFrameCount = 4096
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inputFrames) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            do {
                try file.read(into: inputBuffer)
                if inputBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inputBuffer
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
        }
        if let error { throw error }

        guard let channelData = outputBuffer.floatChannelData else {
            throw NSError(domain: "Audio", code: 3, userInfo: [NSLocalizedDescriptionKey: "No channel data"])
        }
        let frameCount = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }


    // MARK: - Tests

    func testSilenceProducesEmptyOutput() async throws {
        let samples = try loadWAVSamples(named: "silence")
        let text = try await service.transcribe(audioFrames: samples, modelURL: modelURL)
        // Silence should produce empty string or hallucinated phrase that gets filtered
        XCTAssertTrue(
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Expected empty output for silence, got: '\(text)'"
        )
    }

    func testBackgroundNoiseProducesEmptyOrMinimalOutput() async throws {
        let samples = try loadWAVSamples(named: "background-noise")
        let text = try await service.transcribe(audioFrames: samples, modelURL: modelURL)
        // Background noise should produce empty or very short output
        XCTAssertTrue(
            text.count < 20,
            "Expected minimal output for background noise, got: '\(text)'"
        )
    }

    // MARK: - M4A E2E Test

    func testEnglishE2ETest1Transcription() async throws {
        let samples = try loadAudioSamples(named: "english-e2e-test-1", ext: "m4a")
        XCTAssertTrue(samples.count > 0, "Audio samples should not be empty")

        let text = try await service.transcribe(audioFrames: samples, modelURL: modelURL)
        let normalized = text.lowercased()

        // Core phrase must be present (model may vary on capitalization/punctuation)
        XCTAssertTrue(
            normalized.contains("this is me testing that"),
            "Transcription missing core phrase. Got: '\(text)'"
        )
        XCTAssertTrue(
            normalized.contains("end-to-end test") || normalized.contains("end to end test"),
            "Transcription missing 'end-to-end test'. Got: '\(text)'"
        )
        XCTAssertTrue(
            normalized.contains("work properly"),
            "Transcription missing 'work properly'. Got: '\(text)'"
        )
    }

    /// Full pipeline: real transcription → AppState → verify paste, history, status footer, overlay.
    func testEnglishE2ETest1FullPipeline() async throws {
        // 1. Transcribe the m4a with the real model
        let samples = try loadAudioSamples(named: "english-e2e-test-1", ext: "m4a")
        let text = try await service.transcribe(audioFrames: samples, modelURL: modelURL)
        XCTAssertFalse(text.isEmpty, "Transcription should not be empty for this fixture")

        // 2. Wire up an AppState that uses a stub returning the *real* transcription text
        let defaults = UserDefaults(suiteName: "com.openwhisper.test.\(UUID().uuidString)")!
        let env = AppEnvironment(
            audioRecorder: AudioRecorder(mode: .fixture(samples: Array(repeating: 0.1, count: 16000))),
            transcriptionService: TranscriptionService(mode: .stub(result: text)),
            pasteService: PasteService(mode: .spy),
            modelManager: ModelManager(mode: .ready, defaults: defaults),
            permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
            historyStore: HistoryStore(defaults: defaults),
            launchConfig: LaunchConfiguration(
                isTestMode: true, testScenario: nil, defaultsSuiteName: nil,
                disableSparkle: true, disableHotkeys: true, modelPath: nil
            )
        )
        let state = AppState(environment: env)

        // 3. Record → stop → transcribe → paste
        await state.toggleRecording()
        XCTAssertTrue(state.isRecording)
        XCTAssertEqual(state.overlayState.phase, .recording)

        await state.toggleRecording()
        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isTranscribing)

        // 4. Verify: PasteService received the text
        XCTAssertEqual(state.pasteService.pastedTexts.count, 1, "PasteService should have received exactly one paste")
        XCTAssertEqual(state.pasteService.pastedTexts.first, text, "Pasted text should match transcription")

        // 5. Verify: HistoryStore has the entry
        XCTAssertEqual(state.historyStore.entries.count, 1, "History should have exactly one entry")
        XCTAssertEqual(state.historyStore.entries.first?.text, text, "History entry text should match transcription")

        // 6. Verify: Status message (footer) shows "Pasted: ..."
        XCTAssertTrue(state.statusMessage.hasPrefix("Pasted:"), "Status message should show 'Pasted:' prefix, got: '\(state.statusMessage)'")
        let truncatedPreview = String(text.prefix(50))
        XCTAssertTrue(state.statusMessage.contains(truncatedPreview), "Status message should contain preview of transcription")

        // 7. Verify: Overlay dismissed
        XCTAssertEqual(state.overlayState.phase, .hidden, "Overlay should be hidden after transcription completes")
    }
}
