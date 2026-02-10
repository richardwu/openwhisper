import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    let appState: AppState

    var body: some View {
        Form {
            Section("Hotkeys") {
                HStack {
                    Text("Toggle Recording:")
                    Spacer()
                    ShortcutRecorder(name: .toggleRecording)
                }
                HStack {
                    Text("Cancel Recording:")
                    Spacer()
                    ShortcutRecorder(name: .cancelRecording)
                }
            }

            Section("Model") {
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
                HStack {
                    Text("Microphone")
                    Spacer()
                    if Permissions.isMicrophoneAuthorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Request") {
                            Permissions.requestMicrophone()
                        }
                    }
                }

                HStack {
                    Text("Accessibility")
                    Spacer()
                    if Permissions.isAccessibilityGranted {
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
        .frame(width: 400, height: 350)
    }
}
