import AVFoundation
import os

/// Tap callbacks buffer audio synchronously; stopping drains it before finalization.
final class AudioCaptureBuffer: Sendable {
    private struct State {
        var samples: [Float] = []
        var pending: [[Float]] = []
        var accepting = true
        let retainSamples: Bool
        var converter: AVAudioConverter?
        var error: Error?

        mutating func append(_ frames: [Float]) {
            guard !frames.isEmpty else { return }
            if retainSamples {
                samples.append(contentsOf: frames)
            } else {
                pending.append(frames)
            }
        }
    }
    private let state: OSAllocatedUnfairLock<State>

    init(retainSamples: Bool = true, converter: AVAudioConverter? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(retainSamples: retainSamples, converter: converter))
    }

    func append(_ frames: [Float]) -> Bool {
        state.withLock {
            guard $0.accepting else { return false }
            $0.append(frames)
            return true
        }
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        try state.withLock {
            guard $0.accepting, let converter = $0.converter else { return [] }
            do {
                let output = try AudioBufferConversion.convert(input: input, using: converter)
                let frames = Self.samples(output)
                $0.append(frames)
                return frames
            } catch {
                $0.error = error
                $0.accepting = false
                throw error
            }
        }
    }

    func drain() -> [[Float]] {
        state.withLock {
            let pending = $0.pending
            $0.pending.removeAll(keepingCapacity: true)
            return pending
        }
    }

    func finish() -> (samples: [Float], pending: [[Float]], error: Error?) {
        state.withLock {
            // The same lock serializes tap conversion, tail flushing, and stop.
            if $0.accepting, let converter = $0.converter {
                do {
                    while true {
                        let output = try AudioBufferConversion.convert(input: nil, using: converter)
                        guard output.frameLength > 0 else { break }
                        $0.append(Self.samples(output))
                    }
                } catch { $0.error = error }
            }
            $0.accepting = false
            $0.converter = nil
            let result = ($0.samples, $0.pending, $0.error)
            $0.samples = []
            $0.pending = []
            return result
        }
    }

    private static func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength)))
    }
}

/// Shared conversion for microphone capture and Apple's analyzer format.
enum AudioBufferConversion {
    /// A nil input drains the resampler's buffered tail.
    static func convert(input: AVAudioPCMBuffer?, using converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
        let capacity = AVAudioFrameCount(ceil(Double(input?.frameLength ?? 0)
            * converter.outputFormat.sampleRate / converter.inputFormat.sampleRate)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw AudioRecorderError.bufferAllocationFailed
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            guard let input else {
                status.pointee = .endOfStream
                return nil
            }
            guard !consumed else {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard status != .error else { throw AudioRecorderError.conversionFailed }
        return output
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
    @ObservationIgnored var onFailure: ((Error) -> Void)?
    @ObservationIgnored private(set) var lastError: Error?
    @ObservationIgnored var onAudioFrames: (([Float]) -> Void)?

    @ObservationIgnored let levelMeter = AudioLevelMeter()
    var recentLevels: [Float] = Array(repeating: 0, count: 30)
    @ObservationIgnored private var levelTimer: Timer?

    init(mode: Mode = .live) {
        self.mode = mode
    }

    func startRecording(retainSamples: Bool = true) throws {
        lastError = nil
        switch mode {
        case .live:
            try startLiveRecording(retainSamples: retainSamples)
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

    private func startLiveRecording(retainSamples: Bool) throws {
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
        let capture = AudioCaptureBuffer(retainSamples: retainSamples, converter: converter)
        captureBuffer = capture
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer: buffer, meter: meter, capture: capture, streamFrames: !retainSamples)
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
        lastError = result?.error
        for frames in result?.pending ?? [] { onAudioFrames?(frames) }
        recentLevels = Array(repeating: 0, count: 30)
        return result?.samples ?? []
    }

    private nonisolated func convert(
        buffer: AVAudioPCMBuffer,
        meter: AudioLevelMeter,
        capture: AudioCaptureBuffer,
        streamFrames: Bool
    ) {
        let floatArray: [Float]
        do {
            floatArray = try capture.convert(buffer)
        } catch {
            Task { @MainActor [weak self] in
                guard let self, self.captureBuffer === capture else { return }
                self.onFailure?(error)
            }
            return
        }
        guard !floatArray.isEmpty else { return }

        // Compute RMS for level metering
        var sumOfSquares: Float = 0
        for sample in floatArray {
            sumOfSquares += sample * sample
        }
        let rms = sqrtf(sumOfSquares / Float(floatArray.count))
        meter.update(rms)

        if streamFrames {
            Task { @MainActor [weak self] in
                guard let self, self.captureBuffer === capture else { return }
                for frames in capture.drain() { self.onAudioFrames?(frames) }
            }
        }
    }
}

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case converterCreationFailed
    case conversionFailed
    case bufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device found"
        case .bufferAllocationFailed:
            return "Failed to allocate an audio buffer"
        case .conversionFailed:
            return "Failed to convert recorded audio"
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        }
    }
}
