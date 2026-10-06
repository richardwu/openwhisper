import CryptoKit
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
        let base = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/"
        return URL(string: base + fileName)!
    }

    // SHA-256 from Hugging Face LFS metadata at the pinned revision.
    var expectedSHA256: String {
        switch self {
        case .base: return "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
        case .small: return "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
        case .medium: return "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f"
        case .large: return "3a214837221e4530dbc1fe8d734f302af393eb30bd0ed046042ebf4baf70f6f2"
        }
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
            return URL(string: "https://huggingface.co/handy-computer/\(slug)-gguf/resolve/\(revision)/\(fileName)")!
        case .nemotronSpeechStreaming:
            return URL(string: "https://huggingface.co/handy-computer/nemotron-speech-streaming-en-0.6b-gguf/resolve/\(revision)/\(fileName)")!
        case .nemotron35Streaming:
            return URL(string: "https://huggingface.co/handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf/resolve/\(revision)/\(fileName)")!
        case .voxtralMiniRealtime:
            return URL(string: "https://huggingface.co/handy-computer/Voxtral-Mini-4B-Realtime-2602-gguf/resolve/\(revision)/\(fileName)")!
        case .multitalkerParakeetStreaming:
            return URL(string: "https://huggingface.co/handy-computer/multitalker-parakeet-streaming-0.6b-v1-gguf/resolve/\(revision)/bundle/\(fileName)")!
        }
    }

    // SHA-256 from Hugging Face LFS metadata at the pinned revision.
    var expectedSHA256: String {
        switch self {
        case .moonshineStreamingTiny: return "930e4622ad3a24158b91406c30c977fa6a26b34cb32d6ac3e57cfb23383a869e"
        case .moonshineStreamingSmall: return "d03670f69629b649085d0f44a63d97668b4119117cc9611a4e4ad94341713dfc"
        case .moonshineStreamingMedium: return "f7c9564249b508f6012927ec4f9e536087da53a7047f858ca9975bea5f75299e"
        case .nemotronSpeechStreaming: return "dc959ca31499b114e395c44eb4f0778968f20e5cfb03305a08a39925b2da8e1e"
        case .nemotron35Streaming: return "41c99fa5fb6f3d35f68e79adc3e755eca2232a8d921178bd647b71194792b8fd"
        case .voxtralMiniRealtime: return "39dc1f65539373a406edea7490505822d77c12edff521744678717eef4da4723"
        case .multitalkerParakeetStreaming: return "d24307ac22e9e691c146a7e2339891638a44a8492a765e4b6c11cff8960cd998"
        }
    }

    private var revision: String {
        switch self {
        case .moonshineStreamingTiny: return "f33fef628bc4d7ddb419384b1cf28ee83b662b06"
        case .moonshineStreamingSmall: return "7e32b1b3dfce5d3a38dad59630ffce608f15c4aa"
        case .moonshineStreamingMedium: return "0f99e956a9e63d591ddd7f2a20dfead255e96c68"
        case .nemotronSpeechStreaming: return "9789e0ebf77277911272f0d9a35e1646b5aa6004"
        case .nemotron35Streaming: return "8139c4ec14bdc45c361adf8d57c27c28e7478272"
        case .voxtralMiniRealtime: return "65d1c9408859a0ca0f1c11b025ee951486af21d6"
        case .multitalkerParakeetStreaming: return "a9a7208d8f205b5816770a6f7fb83afc81a7691b"
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
            .romanian, .danish, .hungarian, .finnish, .vietnamese, .slovak,
            .bulgarian, .croatian, .estonian, .norwegian,
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
        case missing // Fixture: the selected backend is unavailable.
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

    @ObservationIgnored var onBackendChange: (() -> Void)?

    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration: Int = 0
    private var isNormalizingLanguage = false
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
            if selectedBackend != oldValue {
                if defaults.string(forKey: "selectedLanguage.\(oldValue.rawValue)") == nil {
                    defaults.set(selectedLanguage.rawValue, forKey: "selectedLanguage.\(oldValue.rawValue)")
                }
                if let saved = defaults.string(forKey: "selectedLanguage.\(selectedBackend.rawValue)"),
                   let language = WhisperLanguage(rawValue: saved) {
                    normalizeLanguage(language)
                }
                onBackendChange?()
            }
            defaults.set(selectedBackend.rawValue, forKey: DefaultsKey.selectedBackend)
            // Reset only languages that the selected checkpoint cannot accept.
            // Apple-supported languages are refreshed asynchronously by Settings.
            if selectedBackend.isEnglishOnly {
                normalizeLanguage(.english)
            } else if let supported = selectedBackend.supportedLanguageOptions,
                      !supported.contains(selectedLanguage) {
                normalizeLanguage(.english)
            }
            validateAppleLanguage()
        }
    }

    var selectedLanguage: WhisperLanguage {
        didSet {
            defaults.set(selectedLanguage.rawValue, forKey: DefaultsKey.selectedLanguage)
            if !isNormalizingLanguage {
                defaults.set(selectedLanguage.rawValue, forKey: "selectedLanguage.\(selectedBackend.rawValue)")
            }
        }
    }

    var isModelReady: Bool {
        if selectedBackend == .appleStreaming {
            switch mode {
            case .live:
                return Self.appleStreamingIsAvailable
            case .ready, .fixedPath:
                return true
            case .downloading, .missing, .failed:
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
        let languagePreference = defaults.string(forKey: "selectedLanguage.\(initialSelectedBackend.rawValue)") ?? storedLanguage
        let storedLanguageValue = WhisperLanguage(rawValue: languagePreference) ?? .english
        if initialSelectedBackend.isEnglishOnly {
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
        if defaults.string(forKey: "selectedLanguage.\(selectedBackend.rawValue)") == nil {
            defaults.set(selectedLanguage.rawValue, forKey: "selectedLanguage.\(selectedBackend.rawValue)")
        }
        validateAppleLanguage()
    }

    func normalizeLanguage(_ language: WhisperLanguage) {
        isNormalizingLanguage = true
        selectedLanguage = language
        isNormalizingLanguage = false
    }

    private func validateAppleLanguage() {
        guard case .live = mode, selectedBackend == .appleStreaming else { return }
        if #available(macOS 26.0, *) {
            let language = selectedLanguage
            Task { @MainActor [weak self] in
                let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.appleLocale)
                guard let self, selectedBackend == .appleStreaming, selectedLanguage == language else { return }
                if locale == nil || language == .auto { normalizeLanguage(.english) }
            }
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
        cancelDownload()
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
        cancelDownload()
        downloadTask = Task {
            await downloadModel()
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadGeneration &+= 1
        isDownloading = false
        downloadProgress = 0
        errorMessage = nil
    }

    func downloadModel() async {
        guard !Task.isCancelled else { return }
        let generation = downloadGeneration
        defer {
            if downloadGeneration == generation { isDownloading = false }
        }
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
        let expectedSHA256 = selectedBackend.whisperModel?.expectedSHA256
            ?? selectedBackend.transcribeCppModel?.expectedSHA256
        guard let fileName, let downloadURL, let expectedSHA256 else { return }
        let destinationURL = modelsDir.appendingPathComponent(fileName)

        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        do {
            try Task.checkCancellation()

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300    // 5 min per chunk
            config.timeoutIntervalForResource = 24 * 3600  // Large checkpoints can take hours on slow connections.
            let delegate = DownloadDelegate { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.downloadGeneration == generation else { return }
                    self.downloadProgress = progress
                }
            }

            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: OperationQueue.main)
            defer { session.invalidateAndCancel() }

            let task = session.downloadTask(with: downloadURL)
            let (tempURL, response) = try await withTaskCancellationHandler {
                try await delegate.download(task: task)
            } onCancel: {
                task.cancel()
            }

            defer { try? FileManager.default.removeItem(at: tempURL) }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            try await Self.verifyModelInBackground(at: tempURL, expectedSHA256: expectedSHA256)
            try Task.checkCancellation()
            guard self.downloadGeneration == generation else { return }

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)

            guard self.downloadGeneration == generation else { return }
            isDownloading = false
            downloadProgress = 1.0
        } catch is CancellationError {
            // The generation-guarded defer clears only this download.
        } catch let error as URLError where error.code == .cancelled {
            // The generation-guarded defer clears only this download.
        } catch {
            guard self.downloadGeneration == generation else { return }
            isDownloading = false
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    nonisolated static func verifyModelInBackground(at url: URL, expectedSHA256: String) async throws {
        let verification = Task.detached(priority: .utility) {
            try verifyModel(at: url, expectedSHA256: expectedSHA256)
        }
        try await withTaskCancellationHandler {
            try await verification.value
        } onCancel: {
            verification.cancel()
        }
    }

    nonisolated static func verifyModel(at url: URL, expectedSHA256: String) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256 else {
            throw NSError(domain: "OpenWhisper.ModelDownload", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Model checksum does not match the pinned checkpoint"])
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

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    @MainActor
    func download(task: URLSessionDownloadTask) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled, task.state != .canceling, task.state != .completed else {
                task.cancel()
                continuation.resume(throwing: URLError(.cancelled))
                return
            }
            self.continuation = continuation
            task.resume()
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
        guard let continuation else { return }
        self.continuation = nil
        // Move to a stable temp location before URLSession removes its temporary file.
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        do {
            try FileManager.default.moveItem(at: location, to: tempFile)
            guard let response = downloadTask.response else {
                try? FileManager.default.removeItem(at: tempFile)
                continuation.resume(throwing: URLError(.badServerResponse))
                return
            }
            continuation.resume(returning: (tempFile, response))
        } catch {
            try? FileManager.default.removeItem(at: tempFile)
            continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
