import SwiftUI
import KeyboardShortcuts

struct SettingsTabView: View {
    let appState: AppState
    @State private var micAuthorized = Permissions.isMicrophoneAuthorized
    @State private var accessibilityGranted = Permissions.isAccessibilityGranted

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
        }
    }
}
