import SwiftUI
import KeyboardShortcuts

@MainActor
@Observable
final class AppState {
    var isRecording = false
    var statusMessage = "Ready"
    var isTranscribing = false

    let audioRecorder: AudioRecorder
    let transcriptionService: TranscriptionService
    let pasteService: PasteService
    let modelManager: ModelManager
    let overlayState = OverlayState()
    let historyStore: HistoryStore
    let permissionsClient: PermissionsClient
    private(set) var overlayController: OverlayController?

    private let launchConfig: LaunchConfiguration

    init(environment: AppEnvironment) {
        self.audioRecorder = environment.audioRecorder
        self.transcriptionService = environment.transcriptionService
        self.pasteService = environment.pasteService
        self.modelManager = environment.modelManager
        self.historyStore = environment.historyStore
        self.permissionsClient = environment.permissionsClient
        self.launchConfig = environment.launchConfig

        // Create overlay controller after all properties are initialized
        overlayController = OverlayController(overlayState: overlayState, audioRecorder: audioRecorder)

        if !launchConfig.disableHotkeys {
            KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.toggleRecording()
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

    func toggleRecording() async {
        if isRecording {
            await stopRecordingAndTranscribe()
        } else {
            startRecording()
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        _ = audioRecorder.stopRecording()
        isRecording = false
        statusMessage = "Ready"
        overlayState.phase = .cancelled
        syncCancelRecordingHotkey()

        // Show "Recording Cancelled" briefly, then dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.overlayState.phase = .hidden
            self?.overlayController?.dismiss()
        }
    }

    private func startRecording() {
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
            Self.showMainWindow()
            return
        }

        do {
            try audioRecorder.startRecording()
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
        let samples = audioRecorder.stopRecording()
        isRecording = false
        syncCancelRecordingHotkey()

        guard !samples.isEmpty else {
            statusMessage = "No audio captured"
            overlayState.phase = .hidden
            overlayController?.dismiss()
            return
        }

        guard let modelURL = modelManager.modelFileURL, modelManager.isModelReady else {
            statusMessage = "Model not available"
            overlayState.phase = .hidden
            overlayController?.dismiss()
            return
        }

        isTranscribing = true
        statusMessage = "Transcribing..."
        overlayState.phase = .transcribing

        do {
            let text = try await transcriptionService.transcribe(
                audioFrames: samples,
                modelURL: modelURL,
                language: modelManager.selectedLanguage
            )

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
