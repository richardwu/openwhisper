import XCTest
import SwiftWhisper
@testable import OpenWhisper

final class ModelCatalogTests: XCTestCase {
    @MainActor
    func testLanguageChoiceReturnsAfterUsingEnglishOnlyBackend() {
        let suiteName = "com.openwhisper.backend-language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = ModelManager(mode: .ready, defaults: defaults)
        manager.selectedLanguage = .spanish
        manager.selectedBackend = .parakeetUnified
        XCTAssertEqual(manager.selectedLanguage, .english)
        manager.selectedBackend = .whisperSmall
        XCTAssertEqual(manager.selectedLanguage, .spanish)
        defaults.set(WhisperLanguage.english.rawValue, forKey: "selectedLanguage")
        XCTAssertEqual(ModelManager(mode: .ready, defaults: defaults).selectedLanguage, .spanish)
        defaults.set(WhisperLanguage.spanish.rawValue, forKey: "selectedLanguage.moonshineStreamingSmall")
        manager.selectedBackend = .moonshineStreamingSmall
        XCTAssertEqual(manager.selectedLanguage, .english)
        XCTAssertEqual(defaults.string(forKey: "selectedLanguage.moonshineStreamingSmall"), WhisperLanguage.spanish.rawValue)
        manager.selectedBackend = .moonshineStreamingSmall
        XCTAssertEqual(defaults.string(forKey: "selectedLanguage.moonshineStreamingSmall"), WhisperLanguage.spanish.rawValue)
    }

    @MainActor
    func testDownloadCanceledBeforeResumeCompletesWithoutInvalidatingSession() async {
        let delegate = DownloadDelegate(onProgress: { _ in })
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: .main)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/model.bin")!)
        task.cancel()
        do {
            _ = try await delegate.download(task: task)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
    }

    @MainActor
    func testDownloadWithAlreadyCanceledParentReturnsImmediately() async {
        let delegate = DownloadDelegate(onProgress: { _ in })
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: .main)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/model.bin")!)
        let parent = Task { @MainActor in try await delegate.download(task: task) }
        parent.cancel()
        do {
            _ = try await parent.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
    }

    @MainActor
    func testMissingModelFixtureIsUnavailableForEveryBackend() {
        let suiteName = "com.openwhisper.missing-backends.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = ModelManager(mode: .missing, defaults: defaults)
        for backend in TranscriptionBackend.allCases {
            manager.selectedBackend = backend
            XCTAssertFalse(manager.isModelReady, backend.rawValue)
            XCTAssertFalse(manager.isAvailableLocally(backend), backend.rawValue)
        }
    }

    func testNorwegianUsesApplesBokmalLocaleCode() {
        XCTAssertEqual(WhisperLanguage.norwegian.appleLocale.languageCode, "nb")
    }

    @MainActor
    func testAppleLanguagePersistsAcrossRelaunchAndBackendSelection() {
        let suiteName = "com.openwhisper.apple-language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = ModelManager(mode: .ready, defaults: defaults)
        manager.selectedLanguage = .german
        manager.selectBackend(.appleStreaming)
        XCTAssertEqual(manager.selectedLanguage, .german)
        XCTAssertEqual(ModelManager(mode: .ready, defaults: defaults).selectedLanguage, .german)
        manager.selectBackend(.moonshineStreamingSmall)
        XCTAssertEqual(manager.selectedLanguage, .english)
    }

    @MainActor
    func testCancelledDownloadClearsCurrentProgressState() async {
        let suiteName = "com.openwhisper.cancelled-download.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(TranscriptionBackend.parakeetUnified.rawValue, forKey: "selectedBackend")
        defaults.set(true, forKey: "didMigrateToMultilingual")
        let manager = ModelManager(mode: .live, defaults: defaults)
        manager.configureFluidAudioPreparation { throw CancellationError() }
        await manager.downloadModel()
        XCTAssertFalse(manager.isDownloading)
        XCTAssertNil(manager.errorMessage)
    }

    func testModelDownloadsArePinnedAndChecksumsRejectCorruptFiles() throws {
        let urls = WhisperModel.allCases.map(\.downloadURL) + TranscribeCppModel.allCases.map(\.downloadURL)
        XCTAssertTrue(urls.allSatisfy { !$0.path.contains("/resolve/main/") })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        try ModelManager.verifyModel(at: file, expectedSHA256:
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertThrowsError(try ModelManager.verifyModel(at: file, expectedSHA256: String(repeating: "0", count: 64)))
    }

    @MainActor
    func testCachedLegacyDefaultSmallSurvivesUpgradeAndCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "com.openwhisper.legacy-default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(WhisperLanguage.spanish.rawValue, forKey: "selectedLanguage")
        let legacyFile = directory.appendingPathComponent("ggml-small.en-q5_1.bin")
        try Data().write(to: legacyFile)
        let manager = ModelManager(mode: .live, defaults: defaults, modelsDirectory: directory)
        XCTAssertEqual(manager.selectedBackend, .whisperSmall)
        XCTAssertEqual(manager.selectedLanguage, .spanish)
        XCTAssertEqual(defaults.string(forKey: "selectedBackend"), TranscriptionBackend.whisperSmall.rawValue)
        try? FileManager.default.removeItem(at: legacyFile)
        XCTAssertEqual(ModelManager(mode: .live, defaults: defaults, modelsDirectory: directory).selectedBackend, .whisperSmall)
        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertEqual(ModelManager(mode: .live, defaults: defaults, modelsDirectory: directory).selectedBackend, TranscriptionBackend.preferredDefault)
    }

    @MainActor
    func testLiveEnvironmentReleasesModelManager() {
        let suiteName = "com.openwhisper.environment-release.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        weak var manager: ModelManager?
        autoreleasepool {
            let config = LaunchConfiguration(
                isTestMode: true, testScenario: nil, defaultsSuiteName: suiteName,
                disableSparkle: true, disableHotkeys: true, modelPath: "/missing/model.bin"
            )
            let environment = AppEnvironment.live(config)
            manager = environment.modelManager
        }
        XCTAssertNil(manager, "Backend-change callback must not retain its owner")
    }

    @MainActor
    func testCanceledChecksumVerificationStopsBackgroundWorker() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0, count: 1_048_576).write(to: file)
        let parent = Task { @MainActor in
            try await ModelManager.verifyModelInBackground(at: file, expectedSHA256: String(repeating: "0", count: 64))
        }
        parent.cancel()
        do {
            try await parent.value
            XCTFail("Canceled verification must not complete")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)")
        }
    }

    func testLargeModelUsesAWhisperCppCheckpointSupportedByTheBundledRuntime() {
        XCTAssertEqual(WhisperModel.large.fileName, "ggml-large-v2-q5_0.bin")
        XCTAssertEqual(WhisperModel.large.downloadURL.host, "huggingface.co")
        XCTAssertEqual(
            WhisperModel.large.downloadURL.path,
            "/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v2-q5_0.bin"
        )
        XCTAssertEqual(TranscriptionBackend.whisperLarge.whisperModel, .large)
        XCTAssertTrue(TranscriptionBackend.whisperLarge.requiresWhisperModel)
    }

    func testEverySelectableWhisperModelHasAStableDownloadMetadata() {
        for model in WhisperModel.allCases {
            XCTAssertTrue(model.fileName.hasSuffix(".bin"), model.rawValue)
            XCTAssertEqual(model.downloadURL.host, "huggingface.co", model.rawValue)
            XCTAssertTrue(model.downloadURL.path.contains("/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/"), model.rawValue)
        }
    }

    func testMoonshineStreamingUsesTheHandyGGUFCheckpoint() {
        let model = TranscribeCppModel.moonshineStreamingSmall
        XCTAssertEqual(model.fileName, "moonshine-streaming-small-Q8_0.gguf")
        XCTAssertEqual(model.downloadURL.host, "huggingface.co")
        XCTAssertTrue(model.downloadURL.path.contains("moonshine-streaming-small-gguf"))
        XCTAssertTrue(TranscriptionBackend.moonshineStreamingSmall.isStreamingBackend)
        XCTAssertTrue(TranscriptionBackend.moonshineStreamingSmall.requiresModel)
        XCTAssertNil(TranscriptionBackend.moonshineStreamingSmall.whisperModel)
        XCTAssertEqual(
            TranscriptionBackend.moonshineStreamingSmall.transcribeCppModel,
            .moonshineStreamingSmall
        )
    }

    @MainActor
    func testMoonshineSelectionExposesItsGGUFPathWhenReady() {
        let suiteName = "com.openwhisper.test.moonshine.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(TranscriptionBackend.moonshineStreamingSmall.rawValue, forKey: "selectedBackend")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ModelManager(mode: .ready, defaults: defaults)
        XCTAssertEqual(manager.selectedBackend, .moonshineStreamingSmall)
        XCTAssertTrue(manager.isModelReady)
        XCTAssertEqual(manager.modelFileURL?.path, "/tmp/test-model.bin")
        XCTAssertEqual(manager.selectedLanguage, .english)
    }

    @MainActor
    func testPersistedLargeSelectionMapsToTheLargeBackend() {
        let suiteName = "com.openwhisper.test.model-catalog.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(WhisperModel.large.rawValue, forKey: "selectedModel")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ModelManager(mode: .missing, defaults: defaults)
        XCTAssertEqual(manager.selectedBackend, .whisperLarge)
        XCTAssertEqual(manager.selectedModel, .large)
        XCTAssertFalse(manager.isModelReady)
    }

    func testPendingHandyModelsAreCatalogedButNotSelectable() {
        XCTAssertTrue(LocalModelCatalog.supportedHandyModels.allSatisfy { $0.reasonUnavailable.isEmpty })
        let pendingModels = LocalModelCatalog.pendingHandyModels
        let selectableNames = Set(TranscriptionBackend.allCases.map(\.displayName))
        let pendingIDs = Set(pendingModels.map(\.identifier))
        XCTAssertEqual(
            pendingIDs,
            ["parakeet-v3", "sensevoice", "canary", "gigaam", "breeze-asr"]
        )
        XCTAssertTrue(pendingModels.allSatisfy { !$0.reasonUnavailable.isEmpty })
        for model in pendingModels {
            XCTAssertFalse(selectableNames.contains(model.displayName), model.identifier)
        }
        XCTAssertTrue(TranscriptionBackend.allCases.contains(.parakeetUnified))
        XCTAssertTrue(TranscriptionBackend.allCases.contains(.moonshineStreamingTiny))
        XCTAssertTrue(TranscriptionBackend.allCases.contains(.moonshineStreamingSmall))
        XCTAssertTrue(TranscriptionBackend.allCases.contains(.moonshineStreamingMedium))
        XCTAssertTrue(TranscriptionBackend.allCases.contains(.nemotronSpeechStreaming))
        XCTAssertTrue(TranscriptionBackend.allCases.contains(.nemotron35Streaming))
        XCTAssertTrue(TranscriptionBackend.allCases.contains(.voxtralMiniRealtime))
        XCTAssertTrue(TranscriptionBackend.allCases.contains(.multitalkerParakeetStreaming))
    }

    func testSupportedHandyModelsIncludeEveryStreamingFamily() {
        XCTAssertTrue(TranscriptionBackend.parakeetUnified.isStreamingBackend)
        XCTAssertTrue(TranscriptionBackend.parakeetUnified.isEnglishOnly)
        XCTAssertFalse(TranscriptionBackend.parakeetUnified.requiresWhisperModel)
        XCTAssertEqual(
            LocalModelCatalog.supportedHandyModels.map(\.identifier),
            [
                "parakeet-unified",
                "moonshine-streaming-tiny",
                "moonshine-streaming-small",
                "moonshine-streaming-medium",
                "nemotron-speech-streaming-en-0.6b",
                "nemotron-3.5-asr-streaming-0.6b",
                "voxtral-mini-4b-realtime",
                "multitalker-parakeet-streaming-0.6b-v1",
            ]
        )
    }

    func testFluidAudioCacheMatchesTheParakeetUnifiedRepository() {
        XCTAssertEqual(
            FluidAudioModelSupport.repositoryName,
            "parakeet-unified-en-0.6b"
        )
        XCTAssertTrue(
            FluidAudioModelSupport.requiredFiles.contains(
                "parakeet_unified_encoder_streaming_70_13_13_int8.mlmodelc"
            )
        )
        XCTAssertTrue(FluidAudioModelSupport.requiredFiles.contains("vocab.json"))
    }

    func testTranscribeCppVariantsUseHandyGGUFDownloads() {
        XCTAssertEqual(
            TranscribeCppModel.allCases.map(\.fileName),
            [
                "moonshine-streaming-tiny-Q8_0.gguf",
                "moonshine-streaming-small-Q8_0.gguf",
                "moonshine-streaming-medium-Q8_0.gguf",
                "nemotron-speech-streaming-en-0.6b-Q4_K_M.gguf",
                "nemotron-3.5-asr-streaming-0.6b-Q4_K_M.gguf",
                "Voxtral-Mini-4B-Realtime-2602-Q4_K_M.gguf",
                "multitalker-parakeet-streaming-0.6b-v1-Q4_K_M.gguf",
            ]
        )
        for model in TranscribeCppModel.allCases {
            XCTAssertEqual(model.downloadURL.host, "huggingface.co")
            XCTAssertTrue(model.downloadURL.path.contains("handy-computer"))
        }

        XCTAssertTrue(
            TranscribeCppModel.multitalkerParakeetStreaming.downloadURL.path.contains("/bundle/")
        )
        XCTAssertTrue(
            TranscribeCppModel.nemotronSpeechStreaming.downloadURL.path.contains(
                "nemotron-speech-streaming-en-0.6b-gguf"
            )
        )
        XCTAssertTrue(
            TranscribeCppModel.nemotron35Streaming.downloadURL.path.contains(
                "nemotron-3.5-asr-streaming-0.6b-gguf"
            )
        )
        XCTAssertTrue(
            TranscribeCppModel.voxtralMiniRealtime.downloadURL.path.contains("Voxtral-Mini-4B-Realtime-2602-gguf")
        )
    }

    func testAdditionalStreamingModelsExposeTheirRuntimeFamilies() {
        if case .some(.nemotronSpeechStreaming) = TranscriptionBackend.nemotronSpeechStreaming.transcribeCppStreamFamily {
        } else {
            XCTFail("Nemotron Speech must use the parakeet stream extension")
        }
        if case .some(.nemotron35Streaming) = TranscriptionBackend.nemotron35Streaming.transcribeCppStreamFamily {
        } else {
            XCTFail("Nemotron 3.5 must use its locale-aware stream family")
        }
        if case .some(.voxtralRealtime) = TranscriptionBackend.voxtralMiniRealtime.transcribeCppStreamFamily {
        } else {
            XCTFail("Voxtral must use the realtime stream extension")
        }
        if case .some(.multitalkerParakeetStreaming) = TranscriptionBackend.multitalkerParakeetStreaming.transcribeCppStreamFamily {
        } else {
            XCTFail("Multitalker Parakeet must use the parakeet stream extension")
        }
        XCTAssertTrue(TranscriptionBackend.nemotronSpeechStreaming.isEnglishOnly)
        XCTAssertFalse(TranscriptionBackend.nemotron35Streaming.isEnglishOnly)
        XCTAssertTrue(TranscriptionBackend.voxtralMiniRealtime.isStreamingBackend)
        XCTAssertFalse(TranscriptionBackend.voxtralMiniRealtime.isEnglishOnly)
        XCTAssertTrue(TranscriptionBackend.multitalkerParakeetStreaming.isEnglishOnly)
        XCTAssertEqual(
            TranscriptionBackend.nemotron35Streaming.supportedLanguageOptions,
            [
                .auto, .english, .chinese, .german, .spanish, .russian, .korean,
                .french, .japanese, .portuguese, .turkish, .polish, .dutch,
                .arabic, .swedish, .italian, .hindi, .ukrainian, .czech,
                .romanian, .danish, .hungarian, .finnish, .vietnamese, .slovak,
                .bulgarian, .croatian, .estonian, .norwegian,
            ]
        )
    }

    @MainActor
    func testPersistedParakeetSelectionForcesEnglish() {
        let suiteName = "com.openwhisper.test.parakeet-language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(TranscriptionBackend.parakeetUnified.rawValue, forKey: "selectedBackend")
        defaults.set(WhisperLanguage.japanese.rawValue, forKey: "selectedLanguage")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ModelManager(mode: .live, defaults: defaults)
        XCTAssertEqual(manager.selectedBackend, .parakeetUnified)
        XCTAssertEqual(manager.selectedLanguage, .english)
    }

    @MainActor
    func testStreamingRouterDispatchesToTheSelectedBackend() async throws {
        var selected: TranscriptionBackend = .parakeetUnified
        let parakeet = RecordingStreamingService(result: "parakeet")
        let moonshine = RecordingStreamingService(result: "moonshine")
        let router = BackendStreamingTranscriptionService(
            selectedBackend: { selected },
            services: [
                .parakeetUnified: parakeet,
                .moonshineStreamingSmall: moonshine,
            ]
        )

        router.configure(language: .english, modelURL: nil)
        router.begin()
        router.append(audioFrames: [0.1, 0.2])
        let parakeetResult = try await router.finish()
        XCTAssertEqual(parakeetResult, "parakeet")
        XCTAssertEqual(parakeet.beginCount, 1)
        XCTAssertEqual(moonshine.beginCount, 0)

        selected = .moonshineStreamingSmall
        router.begin()
        let moonshineResult = try await router.finish()
        XCTAssertEqual(moonshineResult, "moonshine")
        XCTAssertEqual(moonshine.beginCount, 1)
    }
}

@MainActor
private final class RecordingStreamingService: StreamingTranscriptionService {
    var onPartialText: ((String) -> Void)?
    let result: String
    var beginCount = 0

    init(result: String) {
        self.result = result
    }

    func configure(language: WhisperLanguage) {}
    func begin() { beginCount += 1 }
    func append(audioFrames: [Float]) {}
    func finish() async throws -> String { result }
    func cancel() {}
}
