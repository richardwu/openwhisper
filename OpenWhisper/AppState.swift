import SwiftUI
import KeyboardShortcuts

@MainActor
@Observable
final class AppState {
    var isRecording = false
    var statusMessage = "Ready"
    var isTranscribing = false

    @ObservationIgnored
    @AppStorage("systemPrompt") var systemPrompt: String = ""

    @ObservationIgnored
    @AppStorage("realtimeTranscriptionEnabled") var realtimeTranscriptionEnabled: Bool = true

    let audioRecorder = AudioRecorder()
    let transcriptionService = TranscriptionService()
    let pasteService = PasteService()
    let modelManager = ModelManager()
    let overlayState = OverlayState()
    let historyStore = HistoryStore()
    let realtimeTranscriptionService = RealtimeTranscriptionService()
    let realtimePasteService = RealtimePasteService()
    private(set) var overlayController: OverlayController?
    private var realtimeTask: Task<Void, Never>?

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
        modelManager.ensureModelAvailable()
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

        realtimeTask?.cancel()
        realtimeTask = nil
        Task { await realtimeTranscriptionService.cancelIfRunning() }
        realtimePasteService.reset()
        overlayState.partialTranscription = ""

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

        if !Permissions.isMicrophoneAuthorized {
            statusMessage = "Microphone permission required"
            Permissions.requestMicrophone()
            Self.showMainWindow()
            return
        }

        do {
            try audioRecorder.startRecording()
            isRecording = true
            statusMessage = "Recording..."
            overlayState.phase = .recording
            overlayController?.show()
            KeyboardShortcuts.enable(.cancelRecording)

            if realtimeTranscriptionEnabled && Permissions.isAccessibilityGranted {
                realtimeTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .seconds(3))
                        } catch {
                            break
                        }

                        guard let self else { break }

                        let samples = audioRecorder.currentSamples()
                        guard samples.count >= 16_000 else { continue }
                        guard let modelURL = modelManager.modelFileURL, modelManager.isModelReady else { continue }

                        do {
                            let text = try await realtimeTranscriptionService.transcribeChunk(
                                audioFrames: samples,
                                modelURL: modelURL
                            )

                            guard !Task.isCancelled else { break }

                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                realtimePasteService.updateText(text)
                                overlayState.partialTranscription = text
                            }
                        } catch is CancellationError {
                            break
                        } catch {
                            // Log and continue — don't crash the realtime loop
                            print("Realtime transcription error: \(error.localizedDescription)")
                            continue
                        }
                    }
                }
            }
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
        realtimeTask?.cancel()
        realtimeTask = nil
        await realtimeTranscriptionService.cancelIfRunning()

        let samples = audioRecorder.stopRecording()
        isRecording = false
        KeyboardShortcuts.disable(.cancelRecording)

        overlayState.partialTranscription = ""

        guard !samples.isEmpty else {
            statusMessage = "No audio captured"
            realtimePasteService.reset()
            overlayState.phase = .hidden
            overlayController?.dismiss()
            return
        }

        guard let modelURL = modelManager.modelFileURL, modelManager.isModelReady else {
            statusMessage = "Model not available"
            realtimePasteService.reset()
            overlayState.phase = .hidden
            overlayController?.dismiss()
            return
        }

        isTranscribing = true
        statusMessage = "Transcribing..."
        overlayState.phase = .transcribing

        do {
            // TODO: Re-enable system prompt once prompt quality is improved
            // let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = try await transcriptionService.transcribe(
                audioFrames: samples,
                modelURL: modelURL
            )

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statusMessage = "No speech detected"
                realtimePasteService.reset()
            } else {
                if realtimePasteService.hasTypedText {
                    realtimePasteService.selectCurrentText()
                    pasteService.paste(text: text)
                    realtimePasteService.reset()
                } else {
                    pasteService.paste(text: text)
                }
                historyStore.add(text: text)
                statusMessage = "Pasted: \(String(text.prefix(50)))\(text.count > 50 ? "..." : "")"
            }
        } catch {
            statusMessage = "Transcription error: \(error.localizedDescription)"
            realtimePasteService.reset()
        }

        isTranscribing = false
        overlayState.phase = .hidden
        overlayController?.dismiss()
    }
}
