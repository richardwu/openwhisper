import AVFoundation
import CoreMedia
import Foundation
import Speech

@MainActor
protocol StreamingTranscriptionService: AnyObject {
    var onPartialText: ((String) -> Void)? { get set }
    func begin()
    func append(audioFrames: [Float])
    func finish() async throws -> String
    func cancel()
}

/// Uses the macOS 26 on-device SpeechTranscriber while the microphone is recording.
/// The app keeps Whisper as a fallback for older systems and unavailable assets.
@available(macOS 26.0, *)
@MainActor
final class AppleStreamingTranscriptionService: StreamingTranscriptionService {
    var onPartialText: ((String) -> Void)?

    private let locale: Locale
    private var startupTask: Task<Void, Error>?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var audioFormat: AVAudioFormat?
    private var pendingFrames: [[Float]] = []
    private var finalText = ""
    private var volatileText = ""
    private var frameOffset: Int64 = 0
    private var didFail = false

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    func begin() {
        cancel()
        pendingFrames = []
        finalText = ""
        volatileText = ""
        frameOffset = 0
        didFail = false
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.prepare()
        }
    }

    func append(audioFrames: [Float]) {
        guard !audioFrames.isEmpty, !didFail else { return }
        guard let continuation, let audioFormat else {
            pendingFrames.append(audioFrames)
            return
        }
        yield(audioFrames, into: continuation, format: audioFormat)
    }

    func finish() async throws -> String {
        try await startupTask?.value

        if let continuation, let audioFormat {
            for frames in pendingFrames {
                yield(frames, into: continuation, format: audioFormat)
            }
        }
        pendingFrames.removeAll(keepingCapacity: false)
        continuation?.finish()
        continuation = nil

        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        resultsTask = nil

        guard !didFail else {
            throw NSError(domain: "OpenWhisper.AppleStreaming", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Apple on-device transcription is unavailable"])
        }
        return finalText + volatileText
    }

    func cancel() {
        startupTask?.cancel()
        startupTask = nil
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        audioFormat = nil
        pendingFrames.removeAll(keepingCapacity: false)
    }

    private func prepare() async throws {
        guard SpeechTranscriber.isAvailable,
              let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            didFail = true
            throw NSError(domain: "OpenWhisper.AppleStreaming", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "SpeechTranscriber is unavailable"])
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)
        ) else {
            didFail = true
            throw NSError(domain: "OpenWhisper.AppleStreaming", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No compatible speech audio format"])
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.audioFormat = format
        self.continuation = continuation
        resultsTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    await MainActor.run { self?.consume(result) }
                }
            } catch {
                await MainActor.run { self?.didFail = true }
            }
        }

        try await analyzer.start(inputSequence: stream)

        if let continuation = self.continuation, let format = self.audioFormat {
            for frames in pendingFrames {
                yield(frames, into: continuation, format: format)
            }
            pendingFrames.removeAll(keepingCapacity: false)
        }
    }

    private func yield(
        _ frames: [Float],
        into continuation: AsyncStream<AnalyzerInput>.Continuation,
        format: AVAudioFormat
    ) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames.count)
        if let destination = buffer.floatChannelData?[0] {
            frames.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress!, count: frames.count)
            }
        } else if let destination = buffer.int16ChannelData?[0] {
            for (index, sample) in frames.enumerated() {
                let clamped = max(-1, min(1, sample))
                destination[index] = Int16(clamped * Float(Int16.max))
            }
        } else {
            return
        }
        let start = CMTime(value: frameOffset, timescale: CMTimeScale(format.sampleRate))
        continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
        frameOffset += Int64(frames.count)
    }

    private func consume(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        if result.isFinal {
            finalText += text
            volatileText = ""
        } else {
            volatileText = text
        }
        onPartialText?(finalText + volatileText)
    }
}
