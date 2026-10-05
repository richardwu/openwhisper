import SwiftUI
import KeyboardShortcuts

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
    private var streamingDidFail = false
    private var recordingBackend: TranscriptionBackend?

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
            guard let self, self.isRecording else { return }
            self.streamingTranscriptionService?.append(audioFrames: frames)
        }
        streamingTranscriptionService?.onPartialText = { [weak self] text in
            guard let self, self.isRecording, !text.isEmpty else { return }
            self.statusMessage = "Recording: \(String(text.prefix(50)))\(text.count > 50 ? "..." : "")"
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
        let shouldStop = hotkeyStartedRecording
        hotkeyStartedRecording = false
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
        guard isRecording else { return }
        hotkeyStartedRecording = false
        _ = audioRecorder.stopRecording()
        streamingTranscriptionService?.cancel()
        recordingBackend = nil
        isRecording = false
        statusMessage = "Ready"
        overlayState.phase = .cancelled
        syncCancelRecordingHotkey()

        // Show "Recording Cancelled" briefly, then dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard self?.overlayState.phase == .cancelled else { return }
            self?.overlayState.phase = .hidden
            self?.overlayController?.dismiss()
        }
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

        do {
            try audioRecorder.startRecording()
            recordingBackend = modelManager.selectedBackend
            streamingDidFail = false
            if modelManager.selectedBackend.isStreamingBackend {
                streamingTranscriptionService?.configure(
                    language: modelManager.selectedLanguage,
                    modelURL: modelManager.modelFileURL
                )
                streamingTranscriptionService?.begin()
            }
            isRecording = true
            statusMessage = "Recording..."
            overlayState.phase = .recording
            overlayController?.show()
            syncCancelRecordingHotkey()
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
        let backend = recordingBackend ?? modelManager.selectedBackend
        let samples = audioRecorder.stopRecording()
        isRecording = false
        syncCancelRecordingHotkey()

        isTranscribing = true
        statusMessage = "Processing..."
        overlayState.phase = .transcribing
        defer {
            isTranscribing = false
            recordingBackend = nil
        }

        var streamedText: String?
        if backend.isStreamingBackend,
           let streamingTranscriptionService, !streamingDidFail {
            do {
                streamedText = try await streamingTranscriptionService.finish()
            } catch {
                streamingDidFail = true
                statusMessage = "\(backend.statusName) error: \(error.localizedDescription)"
                overlayState.phase = .hidden
                overlayController?.dismiss()
                return
            }
        }

        guard !samples.isEmpty else {
            statusMessage = "No audio captured"
            overlayState.phase = .hidden
            overlayController?.dismiss()
            return
        }

        let modelURL = modelManager.modelFileURL
        // Streaming backends own their loaded model inside the streaming
        // service. Their `modelFileURL` is intentionally nil (Apple and
        // FluidAudio) even after a successful finish; only batch Whisper and
        // GGUF backends require a file URL here.
        if !backend.isStreamingBackend &&
           (modelURL == nil || !modelManager.isModelReady) {
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
                    language: modelManager.selectedLanguage
                )
            }

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
                        guard self?.overlayState.phase == .accessibilityRequired else { return }
                        self?.overlayState.phase = .hidden
                        self?.overlayController?.dismiss()
                    }
                    return
                }
            }
        } catch {
            statusMessage = "Transcription error: \(error.localizedDescription)"
        }

        isTranscribing = false
        overlayState.phase = .hidden
        overlayController?.dismiss()
    }

    func syncCancelRecordingHotkey() {
        guard !launchConfig.disableHotkeys else { return }
        if isRecording {
            KeyboardShortcuts.enable(.cancelRecording)
        } else {
            KeyboardShortcuts.disable(.cancelRecording)
        }
    }
}
