import AVFoundation
import os

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
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var samples: [Float] = []
    @ObservationIgnored private let sampleRate: Double = 16000

    @ObservationIgnored let levelMeter = AudioLevelMeter()
    var recentLevels: [Float] = Array(repeating: 0, count: 30)
    @ObservationIgnored private var levelTimer: Timer?

    func startRecording() throws {
        samples = []
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
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer: buffer, converter: converter, targetFormat: targetFormat, meter: meter)
        }

        engine.prepare()
        try engine.start()
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

    func stopRecording() -> [Float] {
        levelTimer?.invalidate()
        levelTimer = nil

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let result = samples
        samples = []
        recentLevels = Array(repeating: 0, count: 30)
        return result
    }

    private nonisolated func convert(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        meter: AudioLevelMeter
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
            self?.samples.append(contentsOf: floatArray)
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
