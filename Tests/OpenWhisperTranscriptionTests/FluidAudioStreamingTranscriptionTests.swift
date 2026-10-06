import AVFoundation
import Darwin
import XCTest
@testable import OpenWhisper

/// Optional hardware integration coverage for the FluidAudio/Core ML backend.
/// The test runs when the local Parakeet Unified cache is already present.
/// It skips clean machines because the first run downloads roughly 600 MB.
@MainActor
final class FluidAudioStreamingTranscriptionTests: XCTestCase {
    func testLongParakeetDictationRemainsResponsiveAndFinishesPromptly() async throws {
        guard ProcessInfo.processInfo.environment["OPENWHISPER_HEADLESS_TESTS"] == "1" else {
            throw XCTSkip("Run scripts/test_background.sh --real-models to prevent screen interaction")
        }
        guard FluidAudioModelSupport.modelsAreAvailable else {
            throw XCTSkip("Parakeet Unified is not cached locally")
        }
        let fixtureURL = try XCTUnwrap(Bundle(for: type(of: self)).url(
            forResource: "english-e2e-test-1", withExtension: "m4a", subdirectory: "Fixtures/Audio"
        ))
        let samples = try readSamples(url: fixtureURL)
        XCTAssertFalse(samples.isEmpty)
        guard !samples.isEmpty else { return }
        let repetitions = Int(ceil(60 * 16_000 / Double(samples.count)))
        let suiteName = "com.openwhisper.parakeet-long.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vocabulary = VocabularyStore(defaults: defaults)
        XCTAssertTrue(vocabulary.learn(term: "OpenWhisper"))
        let finalization = TranscriptionService(mode: .stubError, vocabularyStore: vocabulary)
        let decoder = FluidAudioStreamingTranscriptionService()
        let service = BackendStreamingTranscriptionService(
            selectedBackend: { .parakeetUnified },
            services: [.parakeetUnified: decoder], vocabularyStore: vocabulary
        )
        defer { service.cancel() }
        var latestPartial = ""
        var partialCount = 0
        var changedPartialCount = 0
        service.onPartialText = { text in
            guard !text.isEmpty else { return }
            partialCount += 1
            if text != latestPartial {
                changedPartialCount += 1
                latestPartial = text
            }
        }
        async let firstPreparation: Void = decoder.prepare()
        async let secondPreparation: Void = decoder.prepare()
        _ = try await (firstPreparation, secondPreparation)

        let clock = ContinuousClock()
        var maxHeartbeatGap = 0.0
        let heartbeat = Task { @MainActor in
            var lastBeat = clock.now
            while !Task.isCancelled {
                do { try await clock.sleep(until: lastBeat.advanced(by: .milliseconds(20))) }
                catch { break }
                let now = clock.now
                maxHeartbeatGap = max(maxHeartbeatGap, seconds(lastBeat.duration(to: now)))
                lastBeat = now
            }
        }
        defer { heartbeat.cancel() }
        let start = clock.now
        var nextMemorySample = 15.0
        let initialResidentMiB = try residentMiB()
        var middleResidentMiB: Double?
        print("PARAKEET_LONG start duration_s=\(Double(samples.count * repetitions) / 16_000) rss_mib=\(initialResidentMiB)")
        service.begin()
        var fedSamples = 0
        for _ in 0..<repetitions {
            // The microphone's 4,096-frame tap at 48 kHz produces about 85 ms
            // of 16 kHz PCM. Absolute deadlines avoid slowing the fixture when
            // the main actor is blocked by inference or vocabulary correction.
            for offset in stride(from: 0, to: samples.count, by: 1_360) {
                let end = min(offset + 1_360, samples.count)
                service.append(audioFrames: Array(samples[offset..<end]))
                fedSamples += end - offset
                try await clock.sleep(until: start.advanced(by: .nanoseconds(
                    Int64(fedSamples) * 1_000_000_000 / 16_000
                )))
                let elapsed = seconds(start.duration(to: clock.now))
                if elapsed >= nextMemorySample {
                    let memory = try residentMiB()
                    if elapsed >= 30, middleResidentMiB == nil { middleResidentMiB = memory }
                    print("PARAKEET_LONG sample elapsed_s=\(elapsed) rss_mib=\(memory) partials=\(partialCount) changed=\(changedPartialCount) heartbeat_max_s=\(maxHeartbeatGap)")
                    nextMemorySample += 15
                }
            }
        }
        XCTAssertGreaterThan(changedPartialCount, 1, "Parakeet must stream before recording stops")
        let finishStart = clock.now
        let finalText = await finalization.finalizeTranscription(try await service.finish())
        let finishSeconds = seconds(finishStart.duration(to: clock.now))
        // Let the heartbeat observe any synchronous work immediately before
        // finish() returns, including the final dictionary pass.
        await Task.yield()
        heartbeat.cancel()
        await heartbeat.value
        let finalResidentMiB = try residentMiB()
        let laterGrowthMiB = finalResidentMiB - (middleResidentMiB ?? initialResidentMiB)
        let recurringPhraseCount = finalText.lowercased().components(separatedBy: "this is me testing").count - 1
        print("PARAKEET_LONG final finish_s=\(finishSeconds) heartbeat_max_s=\(maxHeartbeatGap) rss_mib=\(finalResidentMiB) later_growth_mib=\(laterGrowthMiB) partials=\(partialCount) duplicates=\(partialCount - changedPartialCount) repeated_phrases=\(recurringPhraseCount)/\(repetitions)")
        XCTAssertGreaterThanOrEqual(recurringPhraseCount, repetitions - 1, "Long audio lost repeated speech: \(finalText)")
        XCTAssertTrue(finalText.contains("work properly"), finalText)
        XCTAssertTrue(finalText.contains("OpenWhisper"), "Pinned vocabulary was not applied: \(finalText)")
        XCTAssertEqual(partialCount, changedPartialCount, "Unchanged previews should not be published repeatedly")
        XCTAssertLessThan(maxHeartbeatGap, 0.3, "Transcription blocked the main actor")
        XCTAssertLessThan(finishSeconds, 3, "Streaming left too much work until recording stopped")
    }

    func testParakeetUnifiedStreamsFixtureToFinalText() async throws {
        guard FluidAudioModelSupport.modelsAreAvailable else {
            throw XCTSkip("Parakeet Unified is not cached locally")
        }
        guard let url = Bundle(for: type(of: self)).url(
            forResource: "english-e2e-test-1", withExtension: "m4a", subdirectory: "Fixtures/Audio"
        ) else {
            throw XCTSkip("Streaming fixture is not available")
        }

        let samples = try readSamples(url: url)
        let service = FluidAudioStreamingTranscriptionService()
        var partials: [String] = []
        service.onPartialText = { text in
            if !text.isEmpty { partials.append(text) }
        }

        try await service.prepare()
        service.begin()
        service.cancel()
        service.append(audioFrames: samples) // Late audio from a cancelled tap is ignored.
        service.begin()
        for start in stride(from: 0, to: samples.count, by: 3_200) {
            service.append(audioFrames: Array(samples[start..<min(start + 3_200, samples.count)]))
        }
        let text = try await service.finish().lowercased()

        XCTAssertFalse(partials.isEmpty, "Parakeet should publish partial text before finalization")
        XCTAssertTrue(text.contains("this is me testing"), "Unexpected final text: \(text)")
        XCTAssertTrue(text.contains("work properly"), "Unexpected final text: \(text)")

        // Reusing the loaded model must clear the previous stream and ignore
        // audio arriving after finalization.
        service.append(audioFrames: samples)
        service.begin()
        service.append(audioFrames: samples)
        let nextText = try await service.finish().lowercased()
        XCTAssertEqual(nextText, text)
    }

    private func readSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let capacity = AVAudioFrameCount(
            Double(file.length) * 16_000 / file.processingFormat.sampleRate
        ) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var conversionError: NSError?
        _ = AVAudioConverter(from: file.processingFormat, to: format)!.convert(
            to: output,
            error: &conversionError
        ) { _, status in
            guard file.framePosition < file.length else {
                status.pointee = .endOfStream
                return nil
            }
            let frameCount = AVAudioFrameCount(min(4_096, file.length - file.framePosition))
            let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)!
            do {
                try file.read(into: input, frameCount: frameCount)
                if input.frameLength == 0 {
                    status.pointee = .endOfStream
                    return nil
                }
                status.pointee = .haveData
                return input
            } catch {
                status.pointee = .endOfStream
                return nil
            }
        }
        if let conversionError { throw conversionError }
        guard let channel = output.floatChannelData?[0] else {
            throw NSError(domain: "FluidAudioStreamingTranscriptionTests", code: 1)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func residentMiB() throws -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw NSError(domain: "FluidAudioStreamingTranscriptionTests", code: Int(result))
        }
        return Double(info.resident_size) / 1_048_576
    }
}
