import Foundation

/// Dependency container built once from LaunchConfiguration and passed into AppState.
@MainActor
struct AppEnvironment {
    let audioRecorder: AudioRecorder
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

        return AppEnvironment(
            audioRecorder: AudioRecorder(mode: .live),
            transcriptionService: TranscriptionService(mode: .live),
            pasteService: PasteService(mode: .live),
            modelManager: modelManager,
            permissionsClient: PermissionsClient(mode: .live),
            historyStore: HistoryStore(defaults: defaults),
            launchConfig: config
        )
    }

    static func test(scenario: String, suiteName: String = UUID().uuidString) -> AppEnvironment {
        let defaults = UserDefaults(suiteName: suiteName)!
        let config = LaunchConfiguration(
            isTestMode: true,
            testScenario: scenario,
            defaultsSuiteName: suiteName,
            disableSparkle: true,
            disableHotkeys: true,
            modelPath: nil
        )

        let env: AppEnvironment
        switch scenario {
        case "launch_ready_state":
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: [])),
                transcriptionService: TranscriptionService(mode: .stub(result: "")),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .ready, defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
                historyStore: HistoryStore(defaults: defaults),
                launchConfig: config
            )
        case "record_to_transcribe_success":
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: Array(repeating: 0.1, count: 16000))),
                transcriptionService: TranscriptionService(mode: .stub(result: "Hello world")),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .ready, defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
                historyStore: HistoryStore(defaults: defaults),
                launchConfig: config
            )
        case "no_speech":
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: Array(repeating: 0.0, count: 16000))),
                transcriptionService: TranscriptionService(mode: .stub(result: "")),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .ready, defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
                historyStore: HistoryStore(defaults: defaults),
                launchConfig: config
            )
        case "mic_denied":
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: [])),
                transcriptionService: TranscriptionService(mode: .stub(result: "")),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .ready, defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: false, accessibility: true)),
                historyStore: HistoryStore(defaults: defaults),
                launchConfig: config
            )
        case "accessibility_denied":
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: Array(repeating: 0.1, count: 16000))),
                transcriptionService: TranscriptionService(mode: .stub(result: "Hello world")),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .ready, defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: false)),
                historyStore: HistoryStore(defaults: defaults),
                launchConfig: config
            )
        case "model_downloading":
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: [])),
                transcriptionService: TranscriptionService(mode: .stub(result: "")),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .downloading(progress: 0.45), defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
                historyStore: HistoryStore(defaults: defaults),
                launchConfig: config
            )
        case "transcription_error":
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: Array(repeating: 0.1, count: 16000))),
                transcriptionService: TranscriptionService(mode: .stubError),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .ready, defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
                historyStore: HistoryStore(defaults: defaults),
                launchConfig: config
            )
        case "history_management":
            let store = HistoryStore(defaults: defaults)
            store.add(text: "First entry")
            store.add(text: "Second entry")
            store.add(text: "Third entry")
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: [])),
                transcriptionService: TranscriptionService(mode: .stub(result: "")),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .ready, defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
                historyStore: store,
                launchConfig: config
            )
        default:
            // Default test env — everything ready
            env = AppEnvironment(
                audioRecorder: AudioRecorder(mode: .fixture(samples: [])),
                transcriptionService: TranscriptionService(mode: .stub(result: "")),
                pasteService: PasteService(mode: .spy),
                modelManager: ModelManager(mode: .ready, defaults: defaults),
                permissionsClient: PermissionsClient(mode: .mock(microphone: true, accessibility: true)),
                historyStore: HistoryStore(defaults: defaults),
                launchConfig: config
            )
        }
        return env
    }
}
