import Foundation

/// Test scenarios for dependency injection.
enum TestScenario: String, CaseIterable {
    case launchReadyState = "launch_ready_state"
    case recordToTranscribeSuccess = "record_to_transcribe_success"
    case noSpeech = "no_speech"
    case micDenied = "mic_denied"
    case accessibilityDenied = "accessibility_denied"
    case modelDownloading = "model_downloading"
    case transcriptionError = "transcription_error"
    case historyManagement = "history_management"
}

/// Dependency container built once from LaunchConfiguration and passed into AppState.
@MainActor
struct AppEnvironment {
    let audioRecorder: AudioRecorder
    let streamingTranscriptionService: (any StreamingTranscriptionService)?
    let transcriptionService: TranscriptionService
    let pasteService: PasteService
    let modelManager: ModelManager
    let permissionsClient: PermissionsClient
    let historyStore: HistoryStore
    let launchConfig: LaunchConfiguration

    static func live(_ config: LaunchConfiguration = .current) -> AppEnvironment {
        let defaults: UserDefaults
        if let suite = config.defaultsSuiteName {
            defaults = UserDefaults(suiteName: suite) ?? .standard
        } else {
            defaults = .standard
        }

        let modelManager: ModelManager
        if let modelPath = config.modelPath {
            modelManager = ModelManager(mode: .fixedPath(URL(fileURLWithPath: modelPath)), defaults: defaults)
        } else {
            modelManager = ModelManager(mode: .live, defaults: defaults)
        }

        let vocabularyStore = VocabularyStore(defaults: defaults)
        let transcriptionService = TranscriptionService(mode: .live, vocabularyStore: vocabularyStore)
        let parakeetService = FluidAudioStreamingTranscriptionService()
        parakeetService.onPreparationProgress = { [weak modelManager] progress in
            modelManager?.updateFluidAudioProgress(progress)
        }
        modelManager.configureFluidAudioPreparation {
            try await parakeetService.prepare()
        }

        var streamingServices: [TranscriptionBackend: any StreamingTranscriptionService] = [
            .parakeetUnified: parakeetService,
        ]
        for backend in TranscriptionBackend.allCases {
            guard let family = backend.transcribeCppStreamFamily else { continue }
            streamingServices[backend] = TranscribeCppStreamingTranscriptionService(
                modelURLProvider: { @MainActor in modelManager.modelFileURL },
                vocabularyStore: vocabularyStore,
                family: family
            )
        }
        if #available(macOS 26.0, *) {
            streamingServices[.appleStreaming] = AppleStreamingTranscriptionService(vocabularyStore: vocabularyStore)
        }
        let streamingTranscriptionService: (any StreamingTranscriptionService)? =
            BackendStreamingTranscriptionService(
                selectedBackend: { modelManager.selectedBackend },
                services: streamingServices,
                vocabularyStore: vocabularyStore
            )

        return AppEnvironment(
            audioRecorder: AudioRecorder(mode: .live),
            streamingTranscriptionService: streamingTranscriptionService,
            transcriptionService: transcriptionService,
            pasteService: PasteService(mode: .live),
            modelManager: modelManager,
            permissionsClient: PermissionsClient(mode: .live),
            historyStore: HistoryStore(defaults: defaults),
            launchConfig: config
        )
    }

    static func test(scenario: TestScenario, suiteName: String = UUID().uuidString) -> AppEnvironment {
        let defaults = UserDefaults(suiteName: suiteName)!
        let config = LaunchConfiguration(
            isTestMode: true,
            testScenario: scenario.rawValue,
            defaultsSuiteName: suiteName,
            disableSparkle: true,
            disableHotkeys: true,
            modelPath: nil
        )

        let vocabularyStore = VocabularyStore(defaults: defaults)
        let env: AppEnvironment
        switch scenario {
        case .launchReadyState:
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: [])),
                streamingTranscriptionService: nil,
                transcriptionService: TranscriptionService(mode: .stub(result: ""), vocabularyStore: vocabularyStore),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .ready, defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
                historyStore: HistoryStore(defaults: defaults),
                launchConfig: config
            )
        case .recordToTranscribeSuccess:
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: Array(repeating: 0.1, count: 16000))),
                streamingTranscriptionService: nil,
                transcriptionService: TranscriptionService(mode: .stub(result: "Hello world"), vocabularyStore: vocabularyStore),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .ready, defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
                historyStore: HistoryStore(defaults: defaults),
                launchConfig: config
            )
        case .noSpeech:
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: Array(repeating: 0.0, count: 16000))),
                streamingTranscriptionService: nil,
                transcriptionService: TranscriptionService(mode: .stub(result: ""), vocabularyStore: vocabularyStore),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .ready, defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
                historyStore: HistoryStore(defaults: defaults),
                launchConfig: config
            )
        case .micDenied:
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: [])),
                streamingTranscriptionService: nil,
                transcriptionService: TranscriptionService(mode: .stub(result: ""), vocabularyStore: vocabularyStore),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .ready, defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: false, accessibility: true)),
                historyStore: HistoryStore(defaults: defaults),
                launchConfig: config
            )
        case .accessibilityDenied:
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: Array(repeating: 0.1, count: 16000))),
                streamingTranscriptionService: nil,
                transcriptionService: TranscriptionService(mode: .stub(result: "Hello world"), vocabularyStore: vocabularyStore),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .ready, defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: false)),
                historyStore: HistoryStore(defaults: defaults),
                launchConfig: config
            )
        case .modelDownloading:
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: [])),
                streamingTranscriptionService: nil,
                transcriptionService: TranscriptionService(mode: .stub(result: ""), vocabularyStore: vocabularyStore),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .downloading(progress: 0.45), defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
                historyStore: HistoryStore(defaults: defaults),
                launchConfig: config
            )
        case .transcriptionError:
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: Array(repeating: 0.1, count: 16000))),
                streamingTranscriptionService: nil,
                transcriptionService: TranscriptionService(mode: .stubError, vocabularyStore: vocabularyStore),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .ready, defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
                historyStore: HistoryStore(defaults: defaults),
                launchConfig: config
            )
        case .historyManagement:
            let store = HistoryStore(defaults: defaults)
            store.add(text: "First entry")
            store.add(text: "Second entry")
            store.add(text: "Third entry")
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: [])),
                streamingTranscriptionService: nil,
                transcriptionService: TranscriptionService(mode: .stub(result: ""), vocabularyStore: vocabularyStore),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .ready, defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
                historyStore: store,
                launchConfig: config
            )
        }
        return env
    }
}
