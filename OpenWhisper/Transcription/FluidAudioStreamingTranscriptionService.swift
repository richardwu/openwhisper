import AVFoundation
import FluidAudio
import Foundation
import SwiftWhisper

/// A local Parakeet Unified streaming service backed by FluidAudio/Core ML.
///
/// Parakeet Unified is English-only. FluidAudio performs model downloads and
/// Core ML loading locally; the service only sends microphone buffers to the
/// on-device actor and returns its partial/final text.
@MainActor
final class FluidAudioStreamingTranscriptionService: StreamingTranscriptionService {
    var onPartialText: ((String) -> Void)?
    var onPreparationProgress: (@MainActor (Double) -> Void)?

    private let manager: StreamingUnifiedAsrManager
    private var preparationTask: Task<Void, Error>?
    private var startupTask: Task<Void, Error>?
    private var processingTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var finishingTask: Task<String, Error>?
    private var pendingFrames: [[Float]] = []
    private var lastPartial = ""
    private var modelsLoaded = false
    private var isStarting = false
    private var acceptingFrames = false
    private var didFail = false
    private var generation = 0

    init() {
        self.manager = StreamingUnifiedAsrManager()
    }

    /// Downloads and loads the FluidAudio model set. Calling this before a
    /// recording lets the model picker report real readiness and avoids doing
    /// the first Core ML compile after the user starts speaking.
    func prepare() async throws {
        if modelsLoaded { return }

        if let preparationTask {
            try await withTaskCancellationHandler {
                try await preparationTask.value
                try Task.checkCancellation()
            } onCancel: {
                preparationTask.cancel()
            }
            return
        }
        let task = Task {
            try await manager.loadModels(
                to: nil,
                configuration: nil,
                progressHandler: { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        self?.onPreparationProgress?(fraction)
                    }
                }
            )
            try Task.checkCancellation()
            modelsLoaded = true
        }
        preparationTask = task
        defer { preparationTask = nil }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
        }
    }

    func configure(language: WhisperLanguage) {
        // The selected Parakeet Unified checkpoint is English-only. Keep the
        // protocol's language parameter for parity with Apple's service, but
        // do not pass unsupported language identifiers into FluidAudio.
    }

    func configure(language: WhisperLanguage, modelURL: URL?) {
        configure(language: language)
    }

    func begin() {
        cancel()
        generation &+= 1
        let currentGeneration = generation
        pendingFrames.removeAll(keepingCapacity: true)
        didFail = false
        isStarting = true
        acceptingFrames = true
        lastPartial = ""
        let cleanup = cleanupTask

        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                await cleanup?.value
                try Task.checkCancellation()
                if !modelsLoaded {
                    try await prepare()
                }
                guard currentGeneration == generation else { return }
                try await manager.reset()
                guard currentGeneration == generation else { return }
                isStarting = false
                startProcessingIfNeeded()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard currentGeneration == generation else { return }
                didFail = true
                throw error
            }
        }
    }

    func append(audioFrames: [Float]) {
        guard acceptingFrames, !audioFrames.isEmpty, !didFail else { return }
        pendingFrames.append(audioFrames)
        startProcessingIfNeeded()
    }

    func finish() async throws -> String {
        acceptingFrames = false
        let currentGeneration = generation
        defer { if currentGeneration == generation { cancel() } }
        try await startupTask?.value
        guard currentGeneration == generation else { throw CancellationError() }
        await processingTask?.value
        guard currentGeneration == generation else { throw CancellationError() }

        guard !didFail else {
            throw NSError(
                domain: "OpenWhisper.FluidAudio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Parakeet Unified is unavailable"]
            )
        }

        // AppState runs the completed text through TranscriptionService's
        // shared filtering and correction path. Keep this return value raw so
        // the local vocabulary is applied exactly once before paste/history.
        let manager = self.manager
        let task = Task {
            try Task.checkCancellation()
            let text = try await manager.finish()
            _ = await manager.consumeTokenTimings()
            try await manager.reset()
            return text
        }
        finishingTask = task
        let text = try await task.value
        guard currentGeneration == generation else { throw CancellationError() }
        finishingTask = nil
        startupTask = nil
        lastPartial = ""
        return text
    }

    func cancel() {
        generation &+= 1
        let previousStartup = startupTask
        let previousProcessing = processingTask
        let previousCleanup = cleanupTask
        let previousFinish = finishingTask
        finishingTask?.cancel()
        finishingTask = nil
        startupTask?.cancel()
        startupTask = nil
        processingTask?.cancel()
        processingTask = nil
        pendingFrames.removeAll(keepingCapacity: false)
        lastPartial = ""
        didFail = false
        isStarting = false
        acceptingFrames = false

        let manager = self.manager
        cleanupTask = Task {
            await previousCleanup?.value
            _ = try? await previousStartup?.value
            await previousProcessing?.value
            _ = try? await previousFinish?.value
            try? await manager.reset()
        }
    }

    private func startProcessingIfNeeded() {
        guard modelsLoaded, !isStarting, !didFail, processingTask == nil, !pendingFrames.isEmpty else { return }
        let currentGeneration = generation
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if currentGeneration == generation { processingTask = nil }
            }

            do {
                while currentGeneration == generation, !pendingFrames.isEmpty {
                    try Task.checkCancellation()
                    // Drain a backlog in one buffer instead of shifting a
                    // growing queue once for every microphone callback.
                    let frames = pendingFrames.flatMap { $0 }
                    pendingFrames.removeAll(keepingCapacity: true)
                    guard let buffer = makeAudioBuffer(frames) else { continue }
                    try await manager.appendAudio(buffer)
                    try await manager.processBufferedAudio()
                    _ = await manager.consumeTokenTimings()
                    let partial = await manager.getPartialTranscript()
                    guard currentGeneration == generation else { return }
                    guard !partial.isEmpty, partial != lastPartial else { continue }
                    lastPartial = partial
                    onPartialText?(partial)
                }
            } catch is CancellationError {
                return
            } catch {
                if currentGeneration == generation { didFail = true }
            }
        }
    }

    private func makeAudioBuffer(_ frames: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames.count)
        ) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frames.count)
        guard let destination = buffer.floatChannelData?[0] else { return nil }
        frames.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: frames.count)
        }
        return buffer
    }
}
