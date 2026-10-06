import AVFoundation
import CoreMedia
import Foundation
import Speech
import SwiftWhisper

/// Uses the macOS 26 on-device SpeechTranscriber while the microphone is recording.
@available(macOS 26.0, *)
@MainActor
final class AppleStreamingTranscriptionService: StreamingTranscriptionService {
    var onPartialText: ((String) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?

    private var language: WhisperLanguage
    private let vocabularyStore: VocabularyStore?
    private var startupTask: Task<Void, Error>?
    private var cleanupTask: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var audioFormat: AVAudioFormat?
    private var audioConverter: AVAudioConverter?
    private var pendingFrames: [[Float]] = []
    private var finalText = ""
    private var volatileText = ""
    private var frameOffset: Int64 = 0
    private var didFail = false
    private var lastPartial = ""
    private var acceptingFrames = false
    private var generation = 0

    init(vocabularyStore: VocabularyStore? = nil) {
        self.language = .english
        self.vocabularyStore = vocabularyStore
    }

    static func supportedWhisperLanguages() async -> [WhisperLanguage] {
        guard SpeechTranscriber.isAvailable else { return [] }
        let supportedLocales = await SpeechTranscriber.supportedLocales
        return WhisperLanguage.allCases.filter { language in
            guard language != .auto else { return false }
            let languageCode = language.appleLocale.languageCode ?? language.rawValue
            return supportedLocales.contains { locale in
                (locale.languageCode ?? locale.identifier) == languageCode
            }
        }
    }

    func configure(language: WhisperLanguage) {
        self.language = language
    }

    func begin() {
        cancel()
        let currentGeneration = generation
        let cleanup = cleanupTask
        acceptingFrames = true
        pendingFrames = []
        finalText = ""
        volatileText = ""
        frameOffset = 0
        didFail = false
        lastPartial = ""
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await cleanup?.value
                try self.checkSession(generation: currentGeneration)
                try await self.prepare(generation: currentGeneration)
            } catch {
                if currentGeneration == generation, !(error is CancellationError) {
                    didFail = true
                    onFailure?(error)
                }
                throw error
            }
        }
    }

    func append(audioFrames: [Float]) {
        guard acceptingFrames, !audioFrames.isEmpty, !didFail else { return }
        guard let continuation, let audioFormat else {
            pendingFrames.append(audioFrames)
            return
        }
        yield(audioFrames, into: continuation, format: audioFormat)
    }

    func finish() async throws -> String {
        acceptingFrames = false
        let currentGeneration = generation
        defer { if currentGeneration == generation { cancel() } }
        try await startupTask?.value
        try checkSession(generation: currentGeneration)

        if let continuation, let audioFormat {
            for frames in pendingFrames {
                yield(frames, into: continuation, format: audioFormat)
            }
            if let audioConverter {
                do {
                    while true {
                        let tail = try AudioBufferConversion.convert(input: nil, using: audioConverter)
                        guard tail.frameLength > 0 else { break }
                        yield(tail, into: continuation)
                    }
                } catch {
                    didFail = true
                }
            }
        }
        pendingFrames.removeAll(keepingCapacity: false)
        continuation?.finish()
        continuation = nil

        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        try checkSession(generation: currentGeneration)
        await resultsTask?.value
        try checkSession(generation: currentGeneration)
        resultsTask = nil

        guard !didFail else {
            throw NSError(domain: "OpenWhisper.AppleStreaming", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Apple on-device transcription is unavailable"])
        }
        return Self.joinSegments(finalText, volatileText, language: language)
    }

    func cancel() {
        generation &+= 1
        acceptingFrames = false
        startupTask?.cancel()
        startupTask = nil
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        let previousAnalyzer = analyzer
        let previousCleanup = cleanupTask
        cleanupTask = Task {
            await previousCleanup?.value
            await previousAnalyzer?.cancelAndFinishNow()
        }
        analyzer = nil
        transcriber = nil
        audioFormat = nil
        audioConverter = nil
        pendingFrames.removeAll(keepingCapacity: false)
        finalText = ""
        volatileText = ""
        lastPartial = ""
    }

    private func checkSession(generation: Int) throws {
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
    }

    private func prepare(generation: Int) async throws {
        try checkSession(generation: generation)
        guard SpeechTranscriber.isAvailable,
              let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: language.appleLocale) else {
            throw NSError(domain: "OpenWhisper.AppleStreaming", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "SpeechTranscriber is unavailable"])
        }
        try checkSession(generation: generation)

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try checkSession(generation: generation)
            onStatusChange?("Recording (downloading Apple speech model)...")
            try await request.downloadAndInstall()
            try checkSession(generation: generation)
            onStatusChange?("Recording...")
        }
        try checkSession(generation: generation)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)
        ) else {
            throw NSError(domain: "OpenWhisper.AppleStreaming", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No compatible speech audio format"])
        }
        try checkSession(generation: generation)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        if let vocabularyStore {
            let context = AnalysisContext()
            // Apple accepts up to 100 short contextual phrases. Learned terms
            // come first because VocabularyStore ranks them by confidence.
            context.contextualStrings[.general] = Array(vocabularyStore.nativeTerms.prefix(100))
            try await analyzer.setContext(context)
            try checkSession(generation: generation)
        }
        try await analyzer.prepareToAnalyze(in: format)
        try checkSession(generation: generation)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        self.transcriber = transcriber
        self.analyzer = analyzer
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                        channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw AudioRecorderError.converterCreationFailed
        }
        self.audioConverter = converter
        self.audioFormat = format
        self.continuation = continuation
        resultsTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled, self?.generation == generation else { return }
                    self?.consume(result)
                }
            } catch {
                if self?.generation == generation, !(error is CancellationError) {
                    self?.didFail = true
                    self?.onFailure?(error)
                }
            }
        }

        // Queue older frames before start() suspends and append() can run.
        for frames in pendingFrames {
            yield(frames, into: continuation, format: format)
        }
        pendingFrames.removeAll(keepingCapacity: false)
        try checkSession(generation: generation)
        try await analyzer.start(inputSequence: stream)
        try checkSession(generation: generation)
    }

    private func yield(
        _ frames: [Float],
        into continuation: AsyncStream<AnalyzerInput>.Continuation,
        format: AVAudioFormat
    ) {
        guard let converter = audioConverter,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                           frameCapacity: AVAudioFrameCount(frames.count)),
              let destination = input.floatChannelData?[0] else {
            didFail = true
            onFailure?(AudioRecorderError.bufferAllocationFailed)
            return
        }
        input.frameLength = AVAudioFrameCount(frames.count)
        frames.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: frames.count) }
        do {
            let buffer = try AudioBufferConversion.convert(input: input, using: converter)
            yield(buffer, into: continuation)
        } catch {
            // Audio cannot be dropped safely. Fail the recording explicitly.
            didFail = true
            onFailure?(error)
        }
    }

    private func yield(_ buffer: AVAudioPCMBuffer, into continuation: AsyncStream<AnalyzerInput>.Continuation) {
        guard buffer.frameLength > 0 else { return }
        let start = CMTime(value: frameOffset, timescale: CMTimeScale(buffer.format.sampleRate))
        continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
        frameOffset += Int64(buffer.frameLength)
    }

    nonisolated static func joinSegments(_ left: String, _ right: String, language: WhisperLanguage = .english) -> String {
        guard let last = left.last, let first = right.first else { return left + right }
        // Chinese and Japanese words do not require spaces between segments.
        let unspaced = language == .chinese || language == .japanese
        let separator = unspaced || last.isWhitespace || first.isWhitespace || first.isPunctuation ? "" : " "
        return left + separator + right
    }

    private func consume(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        if result.isFinal {
            finalText = Self.joinSegments(finalText, text, language: language)
            volatileText = ""
        } else {
            volatileText = text
        }
        let partial = Self.joinSegments(finalText, volatileText, language: language)
        guard !partial.isEmpty, partial != lastPartial else { return }
        lastPartial = partial
        onPartialText?(partial)
    }
}

extension WhisperLanguage {
    var appleLocale: Locale {
        if self == .auto {
            return Locale.current
        }
        if self == .norwegian {
            return Locale(identifier: "nb-NO")
        }
        if rawValue == "iw" {
            return Locale(identifier: "he")
        }
        if rawValue == "en" {
            return Locale(identifier: "en-US")
        }
        return Locale(identifier: rawValue)
    }
}
