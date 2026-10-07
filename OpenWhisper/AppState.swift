import SwiftUI
import KeyboardShortcuts
import SwiftWhisper

enum RecordingTriggerMode: String, CaseIterable {
    case toggle
    case pressAndHold

    var displayName: String {
        self == .toggle ? "Toggle" : "Press & Hold"
    }

    var instructionTitle: String {
        self == .toggle ? "Press your hotkey to start recording" : "Press and hold your hotkey to record"
    }

    var instructionDetail: String {
        self == .toggle ? "Press again to stop and transcribe" : "Release to stop and transcribe"
    }
}

@MainActor
@Observable
final class AppState {
    var isRecording = false
    var statusMessage = "Ready"
    var isTranscribing = false
    var recordingTriggerMode: RecordingTriggerMode {
        didSet { defaults.set(recordingTriggerMode.rawValue, forKey: "recordingTriggerMode") }
    }

    private let defaults: UserDefaults
    private var activeHotkeyMode: RecordingTriggerMode?
    private var hotkeyStartedRecording = false
    private var hotkeyWasCancelled = false
    private var recordingGeneration = 0

    let audioRecorder: AudioRecorder
    let streamingTranscriptionService: (any StreamingTranscriptionService)?
    let transcriptionService: TranscriptionService
    let pasteService: PasteService
    let modelManager: ModelManager
    let overlayState = OverlayState()
    let historyStore: HistoryStore
    let permissionsClient: PermissionsClient
    private(set) var overlayController: OverlayController?

    private let launchConfig: LaunchConfiguration
    var isTestMode: Bool { launchConfig.isTestMode }
    private var recordingSettings: (backend: TranscriptionBackend, modelURL: URL?, language: WhisperLanguage)?

    init(environment: AppEnvironment) {
        let defaults = environment.launchConfig.defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.defaults = defaults
        self.recordingTriggerMode = RecordingTriggerMode(
            rawValue: defaults.string(forKey: "recordingTriggerMode") ?? ""
        ) ?? .toggle
        self.audioRecorder = environment.audioRecorder
        self.streamingTranscriptionService = environment.streamingTranscriptionService
        self.transcriptionService = environment.transcriptionService
        self.pasteService = environment.pasteService
        self.modelManager = environment.modelManager
        self.historyStore = environment.historyStore
        self.permissionsClient = environment.permissionsClient
        self.launchConfig = environment.launchConfig

        // Background tests exercise the same recording pipeline without panels.
        if !launchConfig.isHeadlessTest {
            overlayController = OverlayController(overlayState: overlayState, audioRecorder: audioRecorder)
        }

        audioRecorder.onAudioFrames = { [weak self] frames in
            guard let self, self.isRecording,
                  self.recordingSettings?.backend.isStreamingBackend == true else { return }
            self.streamingTranscriptionService?.append(audioFrames: frames)
        }
        streamingTranscriptionService?.onPartialText = { [weak self] text in
            guard let self, self.isRecording, !text.isEmpty else { return }
            self.statusMessage = "Recording: \(text.count > 50 ? "..." : "")\(String(text.suffix(50)))"
        }

        streamingTranscriptionService?.onStatusChange = { [weak self] status in
            guard let self, self.isRecording || self.isTranscribing else { return }
            self.statusMessage = status
        }
        streamingTranscriptionService?.onFailure = { [weak self] error in
            self?.recordingFailed(error)
        }
        audioRecorder.onFailure = { [weak self] error in
            self?.recordingFailed(error)
        }

        if !launchConfig.disableHotkeys {
            KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
                self?.recordingHotkeyDown()
            }

            KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.recordingHotkeyUp()
                }
            }

            KeyboardShortcuts.onKeyUp(for: .cancelRecording) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.cancelRecording()
                }
            }

            syncCancelRecordingHotkey()
        }

        // Auto-download model on first launch (skip in test mode)
        if !launchConfig.isTestMode {
            modelManager.ensureModelAvailable()
        }
    }

    func recordingHotkeyDown() {
        guard activeHotkeyMode == nil else { return }
        activeHotkeyMode = recordingTriggerMode
        guard recordingTriggerMode == .pressAndHold, !isRecording, !isTranscribing else { return }
        startRecording()
        hotkeyStartedRecording = isRecording
    }

    func recordingHotkeyUp() async {
        guard let mode = activeHotkeyMode else { return }
        activeHotkeyMode = nil
        let wasCancelled = hotkeyWasCancelled
        hotkeyWasCancelled = false
        let shouldStop = hotkeyStartedRecording
        hotkeyStartedRecording = false
        guard !wasCancelled else { return }
        if mode == .toggle {
            await toggleRecording()
        } else if shouldStop && isRecording {
            await stopRecordingAndTranscribe()
        }
    }

    func toggleRecording() async {
        guard !isTranscribing else { return }
        if isRecording {
            await stopRecordingAndTranscribe()
        } else {
            startRecording()
        }
    }

    func cancelRecording() {
        guard isRecording || isTranscribing else { return }
        stopRecording()
        statusMessage = "Ready"
        overlayState.phase = .cancelled
        let generation = recordingGeneration
        // Show "Recording Cancelled" briefly, then dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard self?.recordingGeneration == generation, self?.overlayState.phase == .cancelled else { return }
            self?.overlayState.phase = .hidden
            self?.overlayController?.dismiss()
        }
    }

    private func stopRecording() {
        guard isRecording || isTranscribing else { return }
        // Keep the latch until release so held keys cannot restart recording.
        hotkeyWasCancelled = activeHotkeyMode != nil
        hotkeyStartedRecording = false
        let wasRecording = isRecording
        isRecording = false
        isTranscribing = false
        recordingGeneration &+= 1
        if wasRecording { _ = audioRecorder.stopRecording() }
        transcriptionService.cancel()
        streamingTranscriptionService?.cancel()
        recordingSettings = nil
        syncCancelRecordingHotkey()
    }

    private func recordingFailed(_ error: Error) {
        guard isRecording || isTranscribing else { return }
        let backend = recordingSettings?.backend ?? modelManager.selectedBackend
        stopRecording()
        statusMessage = "\(backend.statusName) error: \(error.localizedDescription)"
        overlayState.phase = .hidden
        overlayController?.dismiss()
    }

    private func startRecording() {
        if modelManager.selectedBackend.isStreamingBackend && streamingTranscriptionService == nil {
            statusMessage = "Streaming transcription is unavailable on this Mac"
            return
        }
        guard modelManager.isModelReady else {
            if modelManager.isDownloading {
                overlayState.phase = .modelDownloading
                overlayController?.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard self?.overlayState.phase == .modelDownloading else { return }
                    self?.overlayState.phase = .hidden
                    self?.overlayController?.dismiss()
                }
            } else {
                statusMessage = "Model not downloaded yet"
            }
            return
        }

        if !permissionsClient.isMicrophoneAuthorized {
            statusMessage = "Microphone permission required"
            permissionsClient.requestMicrophone()
            if !launchConfig.isHeadlessTest {
                Self.showMainWindow()
            }
            return
        }

        recordingGeneration &+= 1
        do {
            // Tap delivery hops to the main actor, so this synchronous setup
            // pins the decoder before any queued audio callback can run.
            try audioRecorder.startRecording(retainSamples: !modelManager.selectedBackend.isStreamingBackend)
            recordingSettings = (modelManager.selectedBackend, modelManager.modelFileURL, modelManager.selectedLanguage)
            isRecording = true
            statusMessage = "Recording..."
            overlayState.phase = .recording
            overlayController?.show()
            syncCancelRecordingHotkey()
            if modelManager.selectedBackend.isStreamingBackend {
                streamingTranscriptionService?.configure(
                    language: modelManager.selectedLanguage,
                    modelURL: modelManager.modelFileURL
                )
                streamingTranscriptionService?.begin()
            }
        } catch {
            statusMessage = "Mic error: \(error.localizedDescription)"
        }
    }

    static func showMainWindow() {
        guard !LaunchConfiguration.current.isHeadlessTest else { return }
        NSApp.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows {
            if AppIdentity.isMainWindow(window) {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
        if let window = NSApplication.shared.windows.first(where: { !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func stopRecordingAndTranscribe() async {
        let generation = recordingGeneration
        let settings = recordingSettings
        let backend = settings?.backend ?? modelManager.selectedBackend
        let samples = audioRecorder.stopRecording()
        // A synchronous tail callback can fail and cancel this recording.
        guard isRecording else { return }
        if let error = audioRecorder.lastError {
            recordingFailed(error)
            return
        }
        isRecording = false
        isTranscribing = true
        syncCancelRecordingHotkey()
        statusMessage = "Processing..."
        overlayState.phase = .transcribing
        defer {
            if generation == recordingGeneration {
                isTranscribing = false
                recordingSettings = nil
                syncCancelRecordingHotkey()
            }
        }

        var streamedText: String?
        if backend.isStreamingBackend,
           let streamingTranscriptionService {
            do {
                streamedText = try await streamingTranscriptionService.finish()
                guard generation == recordingGeneration else { return }
            } catch {
                guard generation == recordingGeneration else { return }
                statusMessage = "\(backend.statusName) error: \(error.localizedDescription)"
                overlayState.phase = .hidden
                overlayController?.dismiss()
                return
            }
        }

        guard backend.isStreamingBackend || !samples.isEmpty else {
            statusMessage = "No audio captured"
            overlayState.phase = .hidden
            overlayController?.dismiss()
            return
        }

        let modelURL = settings?.modelURL
        // Streaming backends own their loaded model inside the streaming
        // service. Their `modelFileURL` is intentionally nil (Apple and
        // FluidAudio) even after a successful finish; only batch Whisper and
        // GGUF backends require a file URL here.
        if !backend.isStreamingBackend &&
           modelURL == nil {
            statusMessage = "Model not available"
            overlayState.phase = .hidden
            overlayController?.dismiss()
            return
        }

        do {
            let text: String
            if backend.isStreamingBackend {
                // Streaming backends finish the same native stream that ran
                // during capture. An empty result means silence; never start
                // a second Whisper pass after the user stopped recording.
                text = await transcriptionService.finalizeTranscription(streamedText ?? "")
            } else {
                guard let modelURL else {
                    throw NSError(domain: "OpenWhisper", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Whisper model is not available"])
                }
                text = try await transcriptionService.transcribe(
                    audioFrames: samples,
                    modelURL: modelURL,
                    language: settings?.language ?? modelManager.selectedLanguage
                )
            }

            guard generation == recordingGeneration else { return }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statusMessage = "No speech detected"
            } else {
                // Always save to history so the user can retrieve the text later
                historyStore.add(text: text)

                if permissionsClient.isAccessibilityGranted {
                    pasteService.paste(text: text)
                    statusMessage = "Pasted: \(String(text.prefix(50)))\(text.count > 50 ? "..." : "")"
                } else {
                    statusMessage = "Accessibility permission required to paste (saved to history)"
                    overlayState.phase = .accessibilityRequired
                    overlayController?.show()
                    isTranscribing = false

                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                        guard self?.recordingGeneration == generation, self?.overlayState.phase == .accessibilityRequired else { return }
                        self?.overlayState.phase = .hidden
                        self?.overlayController?.dismiss()
                    }
                    return
                }
            }
        } catch {
            guard generation == recordingGeneration else { return }
            statusMessage = "Transcription error: \(error.localizedDescription)"
        }

        isTranscribing = false
        overlayState.phase = .hidden
        overlayController?.dismiss()
    }

    func syncCancelRecordingHotkey() {
        guard !launchConfig.disableHotkeys else { return }
        if isRecording || isTranscribing {
            KeyboardShortcuts.enable(.cancelRecording)
        } else {
            KeyboardShortcuts.disable(.cancelRecording)
        }
    }
}
