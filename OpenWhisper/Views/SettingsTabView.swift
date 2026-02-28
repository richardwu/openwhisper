import SwiftUI
import KeyboardShortcuts

struct SettingsTabView: View {
    let appState: AppState
    @State private var micAuthorized = Permissions.isMicrophoneAuthorized
    @State private var accessibilityGranted = Permissions.isAccessibilityGranted

    @State private var promptText: String = ""
    @State private var isSaving = false
    @State private var showSaved = false
    @State private var saveTask: Task<Void, Never>?
    @State private var hideSavedTask: Task<Void, Never>?

    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let maxPromptLength = 500

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

            Section("System Prompt") {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $promptText)
                        .font(.body)
                        .frame(minHeight: 80, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .onChange(of: promptText) { _, newValue in
                            if newValue.count > maxPromptLength {
                                promptText = String(newValue.prefix(maxPromptLength))
                            }
                            showSaved = false
                            isSaving = true
                            hideSavedTask?.cancel()
                            saveTask?.cancel()
                            saveTask = Task {
                                try? await Task.sleep(for: .milliseconds(250))
                                guard !Task.isCancelled else { return }
                                appState.systemPrompt = promptText
                                isSaving = false
                                showSaved = true
                                hideSavedTask = Task {
                                    try? await Task.sleep(for: .seconds(3))
                                    guard !Task.isCancelled else { return }
                                    showSaved = false
                                }
                            }
                        }

                    if promptText.isEmpty {
                        Text("Guide the transcription with a particular style, or with common words you use. Max ~224 tokens.")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

                HStack(spacing: 4) {
                    Text("\(promptText.count) / \(maxPromptLength)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if isSaving {
                        Text("Saving...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    } else if showSaved {
                        HStack(spacing: 2) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Saved")
                        }
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isSaving)
                .animation(.easeInOut(duration: 0.2), value: showSaved)
            }

            Section("Model") {
                Picker("Model", selection: Binding(
                    get: { appState.modelManager.selectedModel },
                    set: { appState.modelManager.selectModel($0) }
                )) {
                    ForEach(WhisperModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }

                if appState.modelManager.isModelReady {
                    Label("Model ready", systemImage: "checkmark.circle.fill")
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
                            Task {
                                await appState.modelManager.downloadModel()
                            }
                        }
                    }
                } else {
                    Button("Download Model") {
                        Task {
                            await appState.modelManager.downloadModel()
                        }
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
                            Permissions.requestMicrophone()
                        }
                    }
                }

                LabeledContent("Accessibility") {
                    if accessibilityGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Open Settings") {
                            Permissions.openAccessibilitySettings()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(permissionTimer) { _ in
            micAuthorized = Permissions.isMicrophoneAuthorized
            accessibilityGranted = Permissions.isAccessibilityGranted
        }
        .onAppear {
            micAuthorized = Permissions.isMicrophoneAuthorized
            accessibilityGranted = Permissions.isAccessibilityGranted
            promptText = appState.systemPrompt
        }
    }
}
