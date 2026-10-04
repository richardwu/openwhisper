import SwiftUI
import KeyboardShortcuts
import SwiftWhisper

struct SettingsTabView: View {
    let appState: AppState
    @State private var micAuthorized = false
    @State private var accessibilityGranted = false
    @State private var appleLanguageOptions: [WhisperLanguage] = [.english]

    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Hotkeys") {
                LabeledContent("Toggle Recording") {
                    ShortcutRecorder(name: .toggleRecording)
                }
                LabeledContent("Cancel Recording") {
                    ShortcutRecorder(name: .cancelRecording)
                }
            }

            Section("Model") {
                Picker("Transcription", selection: Binding(
                    get: { appState.modelManager.selectedBackend },
                    set: { appState.modelManager.selectBackend($0) }
                )) {
                    ForEach(TranscriptionBackend.allCases, id: \.self) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }

                Picker("Language", selection: Binding(
                    get: { appState.modelManager.selectedLanguage },
                    set: { appState.modelManager.selectedLanguage = $0 }
                )) {
                    ForEach(languageOptions, id: \.self) { language in
                        Text(language.settingsDisplayName).tag(language)
                    }
                }

                if appState.modelManager.isModelReady {
                    Label("(appState.modelManager.selectedBackend.statusName), model ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if appState.modelManager.isDownloading {
                    VStack(alignment: .leading) {
                        Text("Downloading model...")
                        ProgressView(value: appState.modelManager.downloadProgress)
                        Text("\(Int(appState.modelManager.downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let error = appState.modelManager.errorMessage {
                    VStack(alignment: .leading) {
                        Label("Download failed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Retry Download") {
                            appState.modelManager.startDownload()
                        }
                    }
                } else {
                    Button("Download Model") {
                        appState.modelManager.startDownload()
                    }
                }
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    if micAuthorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant Access") {
                            appState.permissionsClient.requestMicrophone()
                        }
                    }
                }

                LabeledContent("Accessibility") {
                    if accessibilityGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Open Settings") {
                            appState.permissionsClient.openAccessibilitySettings()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(permissionTimer) { _ in
            refreshPermissions()
        }
        .onAppear {
            refreshPermissions()
        }
        .task {
            await refreshAppleLanguages()
        }
        .onChange(of: appState.modelManager.selectedBackend) { _, backend in
            guard backend == .appleStreaming else { return }
            Task { await refreshAppleLanguages() }
        }
    }

    private func refreshPermissions() {
        micAuthorized = appState.permissionsClient.isMicrophoneAuthorized
        accessibilityGranted = appState.permissionsClient.isAccessibilityGranted
    }

    private var languageOptions: [WhisperLanguage] {
        if appState.modelManager.selectedBackend == .appleStreaming {
            return appleLanguageOptions
        }
        return [.auto] + WhisperLanguage.allCases.filter { $0 != .auto }
    }

    private func refreshAppleLanguages() async {
        guard #available(macOS 26.0, *) else { return }
        let supported = await AppleStreamingTranscriptionService.supportedWhisperLanguages()
        let options = supported.isEmpty ? [.english] : supported
        await MainActor.run {
            appleLanguageOptions = options
            if appState.modelManager.selectedBackend == .appleStreaming,
               !options.contains(appState.modelManager.selectedLanguage) {
                appState.modelManager.selectedLanguage = .english
            }
        }
    }
}

private extension WhisperLanguage {
    var settingsDisplayName: String {
        if self == .auto {
            return "Auto"
        }

        return String(describing: self)
            .replacingOccurrences(of: "_", with: " ")
            .localizedCapitalized
    }
}
