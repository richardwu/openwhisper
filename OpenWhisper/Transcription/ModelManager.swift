import Foundation
import os
import Speech
import SwiftWhisper

enum WhisperModel: String, CaseIterable {
    case base
    case small
    case medium
    /// Whisper large-v2, quantized to q5_0. The bundled SwiftWhisper runtime
    /// does not support newer large-v3 or turbo checkpoints.
    case large

    var fileName: String {
        switch self {
        case .base:   return "ggml-base.bin"
        case .small:  return "ggml-small-q5_1.bin"
        case .medium: return "ggml-medium-q5_0.bin"
        case .large:  return "ggml-large-v2-q5_0.bin"
        }
    }

    var downloadURL: URL {
        let base = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
        return URL(string: base + fileName)!
    }

    var displayName: String {
        switch self {
        case .base:   return "Base (148 MB, very fast)"
        case .small:  return "Small (163 MB, fast)"
        case .medium: return "Medium (568 MB, not as fast)"
        case .large:  return "Large (1.1 GB, highest quality)"
        }
    }

}

/// GGUF models loaded by Handy's local transcribe.cpp runtime.
enum TranscribeCppModel: String, CaseIterable {
    case moonshineStreamingTiny
    case moonshineStreamingSmall
    case moonshineStreamingMedium
    case nemotronSpeechStreaming
    case nemotron35Streaming
    case voxtralMiniRealtime
    case multitalkerParakeetStreaming

    var fileName: String {
        switch self {
        case .moonshineStreamingTiny: return "moonshine-streaming-tiny-Q8_0.gguf"
        case .moonshineStreamingSmall: return "moonshine-streaming-small-Q8_0.gguf"
        case .moonshineStreamingMedium: return "moonshine-streaming-medium-Q8_0.gguf"
        case .nemotronSpeechStreaming:
            return "nemotron-speech-streaming-en-0.6b-Q4_K_M.gguf"
        case .nemotron35Streaming:
            return "nemotron-3.5-asr-streaming-0.6b-Q4_K_M.gguf"
        case .voxtralMiniRealtime:
            return "Voxtral-Mini-4B-Realtime-2602-Q4_K_M.gguf"
        case .multitalkerParakeetStreaming:
            return "multitalker-parakeet-streaming-0.6b-v1-Q4_K_M.gguf"
        }
    }

    var downloadURL: URL {
        switch self {
        case .moonshineStreamingTiny,
             .moonshineStreamingSmall,
             .moonshineStreamingMedium:
            let slug: String
            switch self {
            case .moonshineStreamingTiny: slug = "moonshine-streaming-tiny"
            case .moonshineStreamingSmall: slug = "moonshine-streaming-small"
            case .moonshineStreamingMedium: slug = "moonshine-streaming-medium"
            default: fatalError("unreachable")
            }
            return URL(string: "https://huggingface.co/handy-computer/\(slug)-gguf/resolve/main/\(fileName)")!
        case .nemotronSpeechStreaming:
            return URL(string: "https://huggingface.co/handy-computer/nemotron-speech-streaming-en-0.6b-gguf/resolve/main/\(fileName)")!
        case .nemotron35Streaming:
            return URL(string: "https://huggingface.co/handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf/resolve/main/\(fileName)")!
        case .voxtralMiniRealtime:
            return URL(string: "https://huggingface.co/handy-computer/Voxtral-Mini-4B-Realtime-2602-gguf/resolve/main/\(fileName)")!
        case .multitalkerParakeetStreaming:
            return URL(string: "https://huggingface.co/handy-computer/multitalker-parakeet-streaming-0.6b-v1-gguf/resolve/main/bundle/\(fileName)")!
        }
    }

    var displayName: String {
        switch self {
        case .moonshineStreamingTiny: return "Moonshine Tiny (50 MB, streaming)"
        case .moonshineStreamingSmall: return "Moonshine Small (199 MB, streaming)"
        case .moonshineStreamingMedium: return "Moonshine Medium (296 MB, streaming)"
        case .nemotronSpeechStreaming:
            return "Nemotron Speech EN 0.6B (475 MB, streaming)"
        case .nemotron35Streaming:
            return "Nemotron 3.5 ASR 0.6B (496 MB, streaming)"
        case .voxtralMiniRealtime:
            return "Voxtral Mini 4B Realtime (2.8 GB, streaming)"
        case .multitalkerParakeetStreaming:
            return "Multitalker Parakeet 0.6B (617 MB, streaming)"
        }
    }
}

enum TranscriptionBackend: String, CaseIterable {
    case appleStreaming
    case parakeetUnified
    case moonshineStreamingTiny
    case moonshineStreamingSmall
    case moonshineStreamingMedium
    case nemotronSpeechStreaming
    case nemotron35Streaming
    case voxtralMiniRealtime
    case multitalkerParakeetStreaming
    case whisperBase
    case whisperSmall
    case whisperMedium
    case whisperLarge

    static var preferredDefault: Self {
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            return .appleStreaming
        }
        return .whisperSmall
    }

    var displayName: String {
        switch self {
        case .appleStreaming: return "Apple (Built-in, streaming)"
        case .parakeetUnified: return "Parakeet Unified 0.6B (609 MB, streaming)"
        case .moonshineStreamingTiny: return TranscribeCppModel.moonshineStreamingTiny.displayName
        case .moonshineStreamingSmall: return TranscribeCppModel.moonshineStreamingSmall.displayName
        case .moonshineStreamingMedium: return TranscribeCppModel.moonshineStreamingMedium.displayName
        case .nemotronSpeechStreaming: return TranscribeCppModel.nemotronSpeechStreaming.displayName
        case .nemotron35Streaming: return TranscribeCppModel.nemotron35Streaming.displayName
        case .voxtralMiniRealtime: return TranscribeCppModel.voxtralMiniRealtime.displayName
        case .multitalkerParakeetStreaming: return TranscribeCppModel.multitalkerParakeetStreaming.displayName
        case .whisperBase: return "Whisper Base (148 MB, batch)"
        case .whisperSmall: return "Whisper Small (163 MB, batch)"
        case .whisperMedium: return "Whisper Medium (568 MB, batch)"
        case .whisperLarge: return "Whisper Large (1.1 GB, batch)"
        }
    }

    var statusName: String {
        displayName.components(separatedBy: " (").first ?? displayName
    }

    /// Relative 0–100 scores from Handy's catalog (`accuracy_score`, `speed_score`):
    /// accuracy derives from benchmark WER, speed from real-time factor on a
    /// Ryzen 4750U. They compare models; they are not % correct or Mac timings.
    /// Parakeet Unified uses Handy's GGUF score for the same base model.
    /// https://github.com/cjpais/Handy/blob/main/src-tauri/src/catalog/catalog.json
    var scores: (accuracy: Int, speed: Int)? {
        switch self {
        case .appleStreaming: return nil
        case .parakeetUnified: return (90, 79)
        case .moonshineStreamingTiny: return (74, 100)
        case .moonshineStreamingSmall: return (84, 95)
        case .moonshineStreamingMedium: return (87, 83)
        case .nemotronSpeechStreaming: return (86, 80)
        case .nemotron35Streaming: return (82, 84)
        case .voxtralMiniRealtime: return (87, 11)
        case .multitalkerParakeetStreaming: return (86, 96)
        case .whisperBase: return (71, 99)
        case .whisperSmall: return (80, 78)
        case .whisperMedium: return (84, 42)
        case .whisperLarge: return (84, 23) // large-v2
        }
    }

    var whisperModel: WhisperModel? {
        switch self {
        case .appleStreaming, .parakeetUnified, .moonshineStreamingTiny,
             .moonshineStreamingSmall, .moonshineStreamingMedium,
             .nemotronSpeechStreaming, .nemotron35Streaming,
             .voxtralMiniRealtime, .multitalkerParakeetStreaming: return nil
        case .whisperBase: return .base
        case .whisperSmall: return .small
        case .whisperMedium: return .medium
        case .whisperLarge: return .large
        }
    }

    var requiresWhisperModel: Bool { whisperModel != nil }

    var isStreamingBackend: Bool {
        switch self {
        case .appleStreaming, .parakeetUnified, .moonshineStreamingTiny,
             .moonshineStreamingSmall, .moonshineStreamingMedium,
             .nemotronSpeechStreaming, .nemotron35Streaming,
             .voxtralMiniRealtime, .multitalkerParakeetStreaming: return true
        case .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge: return false
        }
    }

    var isEnglishOnly: Bool {
        self == .parakeetUnified || self == .moonshineStreamingTiny
            || self == .moonshineStreamingSmall || self == .moonshineStreamingMedium
            || self == .nemotronSpeechStreaming || self == .multitalkerParakeetStreaming
    }

    var transcribeCppModel: TranscribeCppModel? {
        switch self {
        case .moonshineStreamingTiny: return .moonshineStreamingTiny
        case .moonshineStreamingSmall: return .moonshineStreamingSmall
        case .moonshineStreamingMedium: return .moonshineStreamingMedium
        case .nemotronSpeechStreaming: return .nemotronSpeechStreaming
        case .nemotron35Streaming: return .nemotron35Streaming
        case .voxtralMiniRealtime: return .voxtralMiniRealtime
        case .multitalkerParakeetStreaming: return .multitalkerParakeetStreaming
        default: return nil
        }
    }

    var transcribeCppStreamFamily: TranscribeCppStreamFamily? {
        switch self {
        case .moonshineStreamingTiny, .moonshineStreamingSmall, .moonshineStreamingMedium:
            return .moonshineStreaming
        case .nemotronSpeechStreaming:
            return .nemotronSpeechStreaming
        case .nemotron35Streaming:
            return .nemotron35Streaming
        case .voxtralMiniRealtime:
            return .voxtralRealtime
        case .multitalkerParakeetStreaming:
            return .multitalkerParakeetStreaming
        default:
            return nil
        }
    }

    /// BCP-47 locales advertised by Nemotron 3.5 ASR Streaming.
    /// A nil value means the backend uses the full Whisper language picker.
    var supportedLanguageOptions: [WhisperLanguage]? {
        guard self == .nemotron35Streaming else { return nil }
        return [
            .auto, .english, .chinese, .german, .spanish, .russian, .korean,
            .french, .japanese, .portuguese, .turkish, .polish, .dutch,
            .arabic, .swedish, .italian, .hindi, .ukrainian, .czech,
            .romanian, .danish, .hungarian, .thai, .vietnamese, .slovak,
            .bulgarian, .lithuanian, .latvian, .estonian, .norwegian,
        ]
    }

    var requiresModel: Bool {
        whisperModel != nil || transcribeCppModel != nil || self == .parakeetUnified
    }
}

@MainActor
@Observable
final class ModelManager {
    enum Mode {
        case live
        case ready
        case downloading(progress: Double)
        case missing
        case failed(message: String)
        case fixedPath(URL)
    }

    private enum DefaultsKey {
        static let selectedModel = "selectedModel"
        static let selectedBackend = "selectedBackend"
        static let selectedLanguage = "selectedLanguage"
        static let didMigrateToMultilingual = "didMigrateToMultilingual"
    }

    private nonisolated static let legacyEnglishModelFileNames = [
        "ggml-base.en.bin",
        "ggml-small.en-q5_1.bin",
        "ggml-medium.en-q5_0.bin",
    ]


    var isDownloading = false
    var downloadProgress: Double = 0
    var errorMessage: String?

    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration: Int = 0
    private let mode: Mode
    private let defaults: UserDefaults
    private var fluidAudioPreparation: (() async throws -> Void)?

    var selectedModel: WhisperModel {
        didSet {
            defaults.set(selectedModel.rawValue, forKey: DefaultsKey.selectedModel)
        }
    }

    var selectedBackend: TranscriptionBackend {
        didSet {
            defaults.set(selectedBackend.rawValue, forKey: DefaultsKey.selectedBackend)
            // Apple Speech and the bundled streaming models currently expose
            // only English in the settings picker. Nemotron 3.5 exposes a
            // smaller, explicit BCP-47 locale list. Reset a persisted Whisper
            // language when the selected backend cannot accept that language.
            if selectedBackend == .appleStreaming || selectedBackend.isEnglishOnly {
                selectedLanguage = .english
            } else if let supported = selectedBackend.supportedLanguageOptions,
                      !supported.contains(selectedLanguage) {
                selectedLanguage = .english
            }
        }
    }

    var selectedLanguage: WhisperLanguage {
        didSet {
            defaults.set(selectedLanguage.rawValue, forKey: DefaultsKey.selectedLanguage)
        }
    }

    var isModelReady: Bool {
        if selectedBackend == .appleStreaming {
            switch mode {
            case .live:
                return Self.appleStreamingIsAvailable
            case .ready, .fixedPath, .missing:
                return true
            case .downloading, .failed:
                return false
            }
        }
        if selectedBackend == .parakeetUnified {
            switch mode {
            case .live:
                return FluidAudioModelSupport.modelsAreAvailable
            case .ready, .fixedPath:
                return true
            case .downloading, .missing, .failed:
                return false
            }
        }
        switch mode {
        case .ready:
            return true
        case .fixedPath(let url):
            return FileManager.default.fileExists(atPath: url.path)
        case .downloading, .missing, .failed:
            return false
        case .live:
            return modelFileURL != nil
        }
    }

    /// Whether `backend` can run without a download. Used by the model picker.
    func isAvailableLocally(_ backend: TranscriptionBackend) -> Bool {
        if backend == .appleStreaming {
            switch mode {
            case .live:
                return Self.appleStreamingIsAvailable
            case .ready, .fixedPath, .missing:
                return backend == selectedBackend && isModelReady
            case .downloading, .failed:
                return false
            }
        }
        if backend == .parakeetUnified {
            switch mode {
            case .live:
                return FluidAudioModelSupport.modelsAreAvailable
            case .ready, .fixedPath:
                return backend == selectedBackend && isModelReady
            case .downloading, .missing, .failed:
                return false
            }
        }
        guard backend.requiresModel else { return true }
        guard case .live = mode else { return backend == selectedBackend && isModelReady }
        guard let dir = modelsDirectory else { return false }
        let fileName = backend.whisperModel?.fileName ?? backend.transcribeCppModel?.fileName
        guard let fileName else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(fileName).path)
    }

    var modelFileURL: URL? {
        guard let fileName = selectedBackend.whisperModel?.fileName
            ?? selectedBackend.transcribeCppModel?.fileName else { return nil }
        switch mode {
        case .fixedPath(let url):
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .ready:
            // Return a sentinel URL for test mode — TranscriptionService stub won't use it
            return URL(fileURLWithPath: "/tmp/test-model.bin")
        case .downloading, .missing, .failed:
            return nil
        case .live:
            guard let dir = modelsDirectory else { return nil }
            let path = dir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
            return nil
        }
    }

    private var modelsDirectory: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }

        return appSupport
            .appendingPathComponent("OpenWhisper")
            .appendingPathComponent("Models")
    }

    init(mode: Mode = .live, defaults: UserDefaults = .standard) {
        self.mode = mode
        self.defaults = defaults
        let storedModel = defaults.string(forKey: DefaultsKey.selectedModel) ?? ""
        let storedBackend = defaults.string(forKey: DefaultsKey.selectedBackend) ?? ""
        let storedLanguage = defaults.string(forKey: DefaultsKey.selectedLanguage) ?? ""
        let initialBackend: TranscriptionBackend = {
            if case .live = mode {
                return TranscriptionBackend.preferredDefault
            }
            return .whisperSmall
        }()

        self.selectedModel = WhisperModel(rawValue: storedModel) ?? .small
        let persistedBackend = TranscriptionBackend(rawValue: storedBackend)
        let initialSelectedBackend: TranscriptionBackend = {
            guard let persistedBackend else {
                return WhisperModel(rawValue: storedModel).map { Self.backend(for: $0) }
                    ?? initialBackend
            }
            // A previous Apple selection must not leave the app stuck on a
            // backend that this Mac cannot provide after an OS or hardware
            // change. Keep explicit selections for all other backends.
            if persistedBackend == .appleStreaming,
               case .live = mode,
               !Self.appleStreamingIsAvailable {
                return .whisperSmall
            }
            return persistedBackend
        }()
        self.selectedBackend = initialSelectedBackend
        let storedLanguageValue = WhisperLanguage(rawValue: storedLanguage) ?? .english
        if initialSelectedBackend == .appleStreaming || initialSelectedBackend.isEnglishOnly {
            self.selectedLanguage = .english
        } else if let supported = initialSelectedBackend.supportedLanguageOptions,
                  !supported.contains(storedLanguageValue) {
            self.selectedLanguage = .english
        } else {
            self.selectedLanguage = storedLanguageValue
        }

        // Apply test mode initial state
        switch mode {
        case .downloading(let progress):
            self.isDownloading = true
            self.downloadProgress = progress
        case .failed(let message):
            self.errorMessage = message
        case .live:
            let modelsDir = modelsDirectory
            Task.detached(priority: .background) {
                Self.migrateToMultilingualModelsIfNeeded(using: defaults, modelsDirectory: modelsDir)
            }
        default:
            break
        }
    }

    private static var appleStreamingIsAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return SpeechTranscriber.isAvailable
    }

    func ensureModelAvailable() {
        guard case .live = mode else { return }
        if !isModelReady {
            startDownload()
        }
    }

    func selectModel(_ model: WhisperModel) {
        selectBackend(Self.backend(for: model))
    }

    func selectBackend(_ backend: TranscriptionBackend) {
        // Fixture mode exercises the real picker and persistence without
        // downloading model assets or initializing a live recognizer.
        if case .ready = mode {
            selectedBackend = backend
            if let whisperModel = backend.whisperModel {
                selectedModel = whisperModel
            }
            return
        }
        guard case .live = mode else { return }
        guard backend != .appleStreaming || Self.appleStreamingIsAvailable else { return }
        downloadTask?.cancel()
        downloadTask = nil
        downloadGeneration &+= 1
        selectedBackend = backend
        if let whisperModel = backend.whisperModel {
            selectedModel = whisperModel
        }
        if backend.requiresModel && !isModelReady {
            downloadTask = Task {
                await downloadModel()
            }
        } else {
            isDownloading = false
            downloadProgress = 1.0
        }
    }

    func startDownload() {
        guard case .live = mode else { return }
        guard selectedBackend.requiresModel else { return }
        downloadTask?.cancel()
        downloadTask = nil
        downloadGeneration &+= 1
        downloadTask = Task {
            await downloadModel()
        }
    }

    func downloadModel() async {
        if selectedBackend == .parakeetUnified {
            await downloadFluidAudioModel()
            return
        }
        guard let modelsDir = modelsDirectory else {
            errorMessage = "Cannot determine models directory"
            return
        }

        do {
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Cannot create models directory: \(error.localizedDescription)"
            return
        }

        let fileName = selectedBackend.whisperModel?.fileName
            ?? selectedBackend.transcribeCppModel?.fileName
        let downloadURL = selectedBackend.whisperModel?.downloadURL
            ?? selectedBackend.transcribeCppModel?.downloadURL
        guard let fileName, let downloadURL else { return }
        let destinationURL = modelsDir.appendingPathComponent(fileName)

        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        let generation = self.downloadGeneration

        do {
            try Task.checkCancellation()

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300    // 5 min per chunk
            config.timeoutIntervalForResource = 3600  // 1 hour total
            let delegate = DownloadDelegate { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.downloadGeneration == generation else { return }
                    self.downloadProgress = progress
                }
            }

            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: OperationQueue.main)
            defer { session.invalidateAndCancel() }

            let (tempURL, response) = try await withTaskCancellationHandler {
                try await delegate.download(session: session, from: downloadURL)
            } onCancel: {
                session.invalidateAndCancel()
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)

            guard self.downloadGeneration == generation else { return }
            isDownloading = false
            downloadProgress = 1.0
        } catch is CancellationError {
            // Don't reset isDownloading — the replacement download will take over
        } catch let error as URLError where error.code == .cancelled {
            // Don't reset isDownloading — the replacement download will take over
        } catch {
            guard self.downloadGeneration == generation else { return }
            isDownloading = false
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    /// Supplies the concrete FluidAudio service so model preparation and the
    /// first recording share one loaded Core ML manager.
    func configureFluidAudioPreparation(
        _ preparation: @escaping () async throws -> Void
    ) {
        fluidAudioPreparation = preparation
    }

    func updateFluidAudioProgress(_ progress: Double) {
        guard selectedBackend == .parakeetUnified else { return }
        downloadProgress = min(max(progress, 0), 1)
    }

    private func downloadFluidAudioModel() async {
        guard case .live = mode else { return }
        guard let preparation = fluidAudioPreparation else {
            isDownloading = false
            errorMessage = "Parakeet Unified is unavailable in this build"
            return
        }

        isDownloading = true
        downloadProgress = 0
        errorMessage = nil
        let generation = downloadGeneration

        do {
            try await preparation()
            guard downloadGeneration == generation else { return }
            isDownloading = false
            downloadProgress = 1
        } catch is CancellationError {
            // A replacement backend selection owns the next download.
        } catch {
            guard downloadGeneration == generation else { return }
            isDownloading = false
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    private static func backend(for model: WhisperModel) -> TranscriptionBackend {
        switch model {
        case .base: return .whisperBase
        case .small: return .whisperSmall
        case .medium: return .whisperMedium
        case .large: return .whisperLarge
        }
    }

    private nonisolated static let logger = Logger(subsystem: "com.openwhisper.OpenWhisper", category: "ModelManager")

    private nonisolated static func migrateToMultilingualModelsIfNeeded(using defaults: UserDefaults, modelsDirectory: URL?) {
        guard !defaults.bool(forKey: DefaultsKey.didMigrateToMultilingual) else { return }

        guard let modelsDirectory else {
            defaults.set(true, forKey: DefaultsKey.didMigrateToMultilingual)
            return
        }

        var allSucceeded = true
        for legacyFileName in legacyEnglishModelFileNames {
            let legacyURL = modelsDirectory.appendingPathComponent(legacyFileName)
            guard FileManager.default.fileExists(atPath: legacyURL.path) else { continue }

            do {
                try FileManager.default.removeItem(at: legacyURL)
            } catch {
                logger.error("Could not clean up legacy model \(legacyFileName): \(error.localizedDescription)")
                allSucceeded = false
            }
        }

        if allSucceeded {
            defaults.set(true, forKey: DefaultsKey.didMigrateToMultilingual)
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func download(session: URLSession, from url: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Copy to a stable temp location — the file at `location` is deleted when this method returns
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        do {
            try FileManager.default.copyItem(at: location, to: tempFile)
            guard let response = downloadTask.response else {
                continuation?.resume(throwing: URLError(.badServerResponse))
                continuation = nil
                return
            }
            continuation?.resume(returning: (tempFile, response))
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
