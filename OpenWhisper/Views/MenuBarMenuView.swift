import Sparkle
import SwiftUI

struct MenuBarMenuView: View {
    let appState: AppState
    let updater: SPUUpdater

    var body: some View {
        if appState.isRecording {
            Text("Recording...")
        } else if appState.isTranscribing {
            Text("Transcribing...")
        } else if !appState.modelManager.isModelReady {
            if appState.modelManager.isDownloading {
                Text("Downloading model (\(Int(appState.modelManager.downloadProgress * 100))%)...")
            } else {
                Text("Model not downloaded")
            }
        }

        Button(appState.isRecording ? "Stop Recording" : "Start Recording") {
            Task {
                await appState.toggleRecording()
            }
        }
        .disabled(!appState.modelManager.isModelReady || appState.isTranscribing)
        .keyboardShortcut("r")

        Divider()

        Button("Check for Updates...") {
            updater.checkForUpdates()
        }

        Button("Show Main Window") {
            AppState.showMainWindow()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit OpenWhisper") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
