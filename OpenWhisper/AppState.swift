import SwiftUI
import KeyboardShortcuts

@MainActor
@Observable
final class AppState {
    var isRecording = false
    var statusMessage = "Ready"
    var isTranscribing = false

    let audioRecorder = AudioRecorder()
    let transcriptionService = TranscriptionService()
    let pasteService = PasteService()
    let modelManager = ModelManager()
    let overlayState = OverlayState()
    let historyStore = HistoryStore()
    private(set) var overlayController: OverlayController?

    init() {
        // Create overlay controller after all properties are initialized
        overlayController = OverlayController(overlayState: overlayState, audioRecorder: audioRecorder)

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

        // Cancel hotkey starts disabled — only enabled while recording
        KeyboardShortcuts.disable(.cancelRecording)

        // Auto-download model on first launch
        Task {
            await modelManager.ensureModelAvailable()
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
        KeyboardShortcuts.disable(.cancelRecording)

        // Show "Recording Cancelled" briefly, then dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.overlayState.phase = .hidden
            self?.overlayController?.dismiss()
        }
    }

    private func startRecording() {
        guard modelManager.isModelReady else {
            statusMessage = "Model not downloaded yet"
            return
        }

        if !Permissions.isMicrophoneAuthorized {
            statusMessage = "Microphone permission required"
            Permissions.requestMicrophone()
            Self.showMainWindow()
            return
        }

        if !Permissions.isAccessibilityGranted {
            statusMessage = "Accessibility permission required for pasting text"
            overlayState.phase = .accessibilityRequired
            overlayController?.show()
            Permissions.promptAccessibilityIfNeeded()

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard self?.overlayState.phase == .accessibilityRequired else { return }
                self?.overlayState.phase = .hidden
                self?.overlayController?.dismiss()
            }
            return
        }

        do {
            try audioRecorder.startRecording()
            isRecording = true
            statusMessage = "Recording..."
            overlayState.phase = .recording
            overlayController?.show()
            KeyboardShortcuts.enable(.cancelRecording)
        } catch {
            statusMessage = "Mic error: \(error.localizedDescription)"
        }
    }

    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows {
            if window.identifier?.rawValue == "main" ||
               window.title == "OpenWhisper" {
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
        KeyboardShortcuts.disable(.cancelRecording)

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
                modelURL: modelURL
            )

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statusMessage = "No speech detected"
            } else {
                pasteService.paste(text: text)
                historyStore.add(text: text)
                statusMessage = "Pasted: \(String(text.prefix(50)))\(text.count > 50 ? "..." : "")"
            }
        } catch {
            statusMessage = "Transcription error: \(error.localizedDescription)"
        }

        isTranscribing = false
        overlayState.phase = .hidden
        overlayController?.dismiss()
    }
}
