// Standalone on-device experiment. Requires the macOS 26 SDK and runtime.
// Usage: apple-streaming-replay AUDIO OUTPUT_JSON [chunk_seconds] [limit_seconds|0] [fast|normal] [repeat_count]
// Each chunk is paced at 1x. Setup/download time is outside replay timing.
// This measures recognition/finalization, not microphone capture or OS paste.
import Foundation
@preconcurrency import AVFoundation
import Speech
import CoreMedia

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func log(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

actor Results {
    var events: [[String: Any]] = []
    var finalText = ""
    var firstResult: Double?
    var firstPartial: Double?
    var lastFinal: Double?
    var latestPreview = ""
    func append(_ result: SpeechTranscriber.Result, started: Double) {
        let timestamp = now()
        let text = String(result.text.characters)
        if firstResult == nil { firstResult = timestamp }
        if !result.isFinal && firstPartial == nil { firstPartial = timestamp }
        if result.isFinal { finalText += text; lastFinal = timestamp; latestPreview = "" }
        else { latestPreview = text }
        let event: [String: Any] = ["kind": "result", "elapsed_seconds": timestamp-started,
            "is_final": result.isFinal, "text": text,
            "audio_start_seconds": result.range.start.seconds,
            "audio_end_seconds": result.range.end.seconds]
        events.append(event)
        log(event)
    }
    func snapshot(started: Double, stopped: Double, finished: Double) -> [String: Any] {
        ["events": events, "final_text": finalText,
         "first_result_seconds": firstResult.map { $0-started } as Any? ?? NSNull(),
         "first_partial_seconds": firstPartial.map { $0-started } as Any? ?? NSNull(),
         "last_final_after_stop_seconds": lastFinal.map { $0-stopped } as Any? ?? NSNull(),
         "final_ready_after_stop_seconds": lastFinal.map { max(0, $0-stopped) } as Any? ?? NSNull(),
         "stop_to_finished_seconds": finished-stopped,
         "replay_seconds": stopped-started]
    }
    func atStop(started: Double, stopped: Double) -> [String: Any] {
        var final = ""
        var preview = ""
        for event in events where (event["elapsed_seconds"] as! Double) <= stopped-started {
            if event["is_final"] as! Bool { final += event["text"] as! String; preview = "" }
            else { preview = event["text"] as! String }
        }
        return ["final_text_at_stop": final, "preview_text_at_stop": preview]
    }
}

@main struct Replay {
    static func main() async {
        do { try await run() }
        catch { log(["kind":"error", "error": String(describing: error)]); exit(1) }
    }
    static func run() async throws {
        guard CommandLine.arguments.count >= 3 else {
            log(["error":"usage: apple-streaming-replay AUDIO OUTPUT_JSON [chunk_seconds] [limit_seconds|0] [fast|normal] [repeat_count]"])
            exit(2)
        }
        let input = CommandLine.arguments[1]
        let output = CommandLine.arguments[2]
        let args = CommandLine.arguments
        guard args.count <= 7,
              let chunkSeconds = args.count > 3 ? Double(args[3]) : 0.2,
              let limitSeconds = args.count > 4 ? Double(args[4]) : 0,
              let repeatCount = args.count > 6 ? Int(args[6]) : 1,
              chunkSeconds.isFinite, chunkSeconds > 0, chunkSeconds <= 10,
              limitSeconds.isFinite, limitSeconds >= 0,
              (1...100).contains(repeatCount),
              args.count <= 5 || ["fast", "normal"].contains(args[5]) else {
            throw NSError(domain:"Replay", code:6, userInfo:[NSLocalizedDescriptionKey:"Invalid replay arguments"])
        }
        let fast = args.count > 5 && args[5] == "fast"
        let installedLocales = await SpeechTranscriber.installedLocales.map(\.identifier)
        let supportedLocales = await SpeechTranscriber.supportedLocales.map(\.identifier)
        log(["kind":"availability", "is_available": SpeechTranscriber.isAvailable,
             "installed_locales": installedLocales, "supported_locales": supportedLocales])
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier:"en-US")) else {
            throw NSError(domain:"Replay", code:1, userInfo:[NSLocalizedDescriptionKey:"SpeechTranscriber unavailable"])
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: fast ? [.volatileResults, .fastResults] : [.volatileResults], attributeOptions: [.audioTimeRange])
        log(["kind":"assets", "status": String(describing: await AssetInventory.status(forModules: [transcriber]))])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let began = now()
            log(["kind":"asset_install_started"])
            try await request.downloadAndInstall()
            log(["kind":"asset_install_finished", "seconds": now()-began])
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: input))
        let requestedSeconds = limitSeconds > 0 ? min(limitSeconds, Double(file.length)/file.processingFormat.sampleRate) : Double(file.length)/file.processingFormat.sampleRate
        let sourceLimit = min(file.length, Int64(ceil(requestedSeconds*file.processingFormat.sampleRate)))
        guard sourceLimit > 0, sourceLimit < Int64(UInt32.max), let source = AVAudioPCMBuffer(pcmFormat:file.processingFormat, frameCapacity:UInt32(sourceLimit)) else {
            throw NSError(domain:"Replay",code:2)
        }
        try file.read(into:source)
        guard Int64(source.frameLength) == sourceLimit else {
            throw NSError(domain:"Replay", code:7, userInfo:[NSLocalizedDescriptionKey:"Audio read did not include every requested frame"])
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:[transcriber], considering:file.processingFormat),
              let converter = AVAudioConverter(from:file.processingFormat, to:format),
              let converted = AVAudioPCMBuffer(pcmFormat:format, frameCapacity:UInt32(ceil(Double(source.frameLength)*format.sampleRate/file.processingFormat.sampleRate))+1024) else {
            throw NSError(domain:"Replay",code:3)
        }
        var consumed = false
        var conversionError: NSError?
        let conversion = converter.convert(to: converted, error:&conversionError) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData; return source
        }
        if let conversionError { throw conversionError }
        guard conversion != .error, converted.frameLength > 0 else { throw NSError(domain:"Replay", code:4) }
        log(["kind":"audio", "source_frames":source.frameLength, "source_sample_rate":file.processingFormat.sampleRate,
            "converted_frames":converted.frameLength, "sample_rate":format.sampleRate,
            "audio_seconds":Double(converted.frameLength)/format.sampleRate,
            "format":format.description, "conversion_status":String(describing:conversion)])
        let analyzer = SpeechAnalyzer(modules:[transcriber])
        let prepared = now()
        try await analyzer.prepareToAnalyze(in:format)
        log(["kind":"prepared", "seconds":now()-prepared])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let results = Results()
        let started = now()
        let resultTask = Task {
            for try await result in transcriber.results { await results.append(result, started:started) }
        }
        try await analyzer.start(inputSequence:stream)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(converted.mutableAudioBufferList)
        let framesPerChunk = UInt32(round(chunkSeconds*format.sampleRate))
        guard framesPerChunk > 0, UInt64(converted.frameLength)*UInt64(repeatCount) <= UInt64(UInt32.max) else {
            throw NSError(domain:"Replay", code:8, userInfo:[NSLocalizedDescriptionKey:"Replay frame count is out of range"])
        }
        let totalFrames = converted.frameLength * UInt32(repeatCount)
        var sent: UInt32 = 0
        var chunks = 0
        while sent < totalFrames {
            let clipOffset = sent % converted.frameLength
            let count = min(framesPerChunk, converted.frameLength-clipOffset, totalFrames-sent)
            let due = started + Double(sent+count)/format.sampleRate
            let delay = due-now()
            if delay > 0 { try await Task.sleep(nanoseconds:UInt64(delay*1e9)) }
            guard let chunk = AVAudioPCMBuffer(pcmFormat:format, frameCapacity:count) else { throw NSError(domain:"Replay",code:5) }
            chunk.frameLength = count
            let destination = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
            for i in destination.indices {
                memcpy(destination[i].mData!, sourceBuffers[i].mData!.advanced(by:Int(clipOffset)*bytesPerFrame),Int(count)*bytesPerFrame)
            }
            continuation.yield(AnalyzerInput(buffer:chunk, bufferStartTime:CMTime(value:Int64(sent),timescale:Int32(format.sampleRate))))
            sent += count; chunks += 1
        }
        let stopped = now()
        let atStop = await results.atStop(started:started, stopped:stopped)
        log(["kind":"stop", "elapsed_seconds":stopped-started, "sent_frames":sent, "chunk_count":chunks,
            "final_text_at_stop":atStop["final_text_at_stop"]!, "preview_text_at_stop":atStop["preview_text_at_stop"]!])
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await resultTask.value
        let finished = now()
        var report = await results.snapshot(started:started, stopped:stopped, finished:finished)
        report.merge(await results.atStop(started:started, stopped:stopped)) { _, new in new }
        report["input_path"] = input
        report["engine"] = "Apple SpeechTranscriber"
        report["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        report["is_available"] = SpeechTranscriber.isAvailable
        report["installed_locales"] = installedLocales
        report["supported_locales"] = supportedLocales
        report["format"] = format.description
        report["pace"] = "real-time 1x, each chunk yielded after its capture duration"
        report["locale"] = locale.identifier
        report["source_frames"] = source.frameLength
        report["original_source_frames"] = file.length
        report["limit_seconds"] = limitSeconds
        report["fast_results"] = fast
        report["source_sample_rate"] = file.processingFormat.sampleRate
        report["sent_frames"] = sent
        report["converted_frames"] = converted.frameLength
        report["repeat_count"] = repeatCount
        report["total_input_frames"] = totalFrames
        report["sample_rate"] = format.sampleRate
        report["audio_seconds"] = Double(totalFrames)/format.sampleRate
        report["chunk_seconds"] = chunkSeconds
        report["chunk_count"] = chunks
        let data = try JSONSerialization.data(withJSONObject:report, options:[.prettyPrinted,.sortedKeys])
        try data.write(to:URL(fileURLWithPath:output))
        log(["kind":"summary", "output_path":output, "final_text":report["final_text"]!,
            "first_result_seconds":report["first_result_seconds"]!, "stop_to_finished_seconds":finished-stopped])
    }
}
