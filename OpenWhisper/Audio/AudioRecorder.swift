import AVFoundation
import os

/// Tap callbacks buffer audio synchronously; stopping drains it before finalization.
final class AudioCaptureBuffer: Sendable {
    private struct State {
        var samples: [Float] = []
        var pending: [[Float]] = []
        var accepting = true
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func append(_ frames: [Float]) -> Bool {
        state.withLock {
            guard $0.accepting else { return false }
            $0.samples.append(contentsOf: frames)
            $0.pending.append(frames)
            return true
        }
    }

    func drain() -> [[Float]] {
        state.withLock {
            let pending = $0.pending
            $0.pending.removeAll(keepingCapacity: true)
            return pending
        }
    }

    func finish() -> (samples: [Float], pending: [[Float]]) {
        state.withLock {
            $0.accepting = false
            let result = ($0.samples, $0.pending)
            $0.samples = []
            $0.pending = []
            return result
        }
    }
}

final class AudioLevelMeter: Sendable {
    private let _lock = OSAllocatedUnfairLock(initialState: Float(0))

    func update(_ rms: Float) {
        _lock.withLock { $0 = rms }
    }

    func read() -> Float {
        _lock.withLock { $0 }
    }
}

@MainActor
@Observable
final class AudioRecorder {
    enum Mode {
        case live
        case fixture(samples: [Float])
    }

    @ObservationIgnored private let mode: Mode
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var captureBuffer: AudioCaptureBuffer?
    @ObservationIgnored private let sampleRate: Double = 16000
    @ObservationIgnored var onAudioFrames: (([Float]) -> Void)?

    @ObservationIgnored let levelMeter = AudioLevelMeter()
    var recentLevels: [Float] = Array(repeating: 0, count: 30)
    @ObservationIgnored private var levelTimer: Timer?

    init(mode: Mode = .live) {
        self.mode = mode
    }

    func startRecording() throws {
        switch mode {
        case .live:
            try startLiveRecording()
        case .fixture:
            // Fixture mode: no-op on start, samples returned on stop
            recentLevels = Array(repeating: 0.1, count: 30)
        }
    }

    func stopRecording() -> [Float] {
        switch mode {
        case .live:
            return stopLiveRecording()
        case .fixture(let fixtureSamples):
            recentLevels = Array(repeating: 0, count: 30)
            return fixtureSamples
        }
    }

    // MARK: - Live Implementation

    private func startLiveRecording() throws {
        recentLevels = Array(repeating: 0, count: 30)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.converterCreationFailed
        }

        let meter = levelMeter
        let capture = AudioCaptureBuffer()
        captureBuffer = capture
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer: buffer, converter: converter, targetFormat: targetFormat, meter: meter, capture: capture)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            _ = capture.finish()
            captureBuffer = nil
            throw error
        }
        self.engine = engine

        // 30fps timer to update recentLevels
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let level = self.levelMeter.read()
                self.recentLevels.append(level)
                if self.recentLevels.count > 30 {
                    self.recentLevels.removeFirst()
                }
            }
        }
    }

    private func stopLiveRecording() -> [Float] {
        levelTimer?.invalidate()
        levelTimer = nil

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let result = captureBuffer?.finish()
        captureBuffer = nil
        for frames in result?.pending ?? [] { onAudioFrames?(frames) }
        recentLevels = Array(repeating: 0, count: 30)
        return result?.samples ?? []
    }

    private nonisolated func convert(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        meter: AudioLevelMeter,
        capture: AudioCaptureBuffer
    ) {
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * (targetFormat.sampleRate / buffer.format.sampleRate)
        )
        guard frameCapacity > 0 else { return }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return
        }

        var error: NSError?
        var inputConsumed = false

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputConsumed = true
            return buffer
        }

        guard error == nil else { return }

        let floatArray = Array(UnsafeBufferPointer(
            start: outputBuffer.floatChannelData?[0],
            count: Int(outputBuffer.frameLength)
        ))
        guard !floatArray.isEmpty, capture.append(floatArray) else { return }

        // Compute RMS for level metering
        if !floatArray.isEmpty {
            var sumOfSquares: Float = 0
            for sample in floatArray {
                sumOfSquares += sample * sample
            }
            let rms = sqrtf(sumOfSquares / Float(floatArray.count))
            meter.update(rms)
        }

        Task { @MainActor [weak self] in
            guard let self, self.captureBuffer === capture else { return }
            for frames in capture.drain() { self.onAudioFrames?(frames) }
        }
    }
}

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device found"
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        }
    }
}
