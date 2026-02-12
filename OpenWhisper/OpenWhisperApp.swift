import Sparkle
import SwiftUI

@main
struct OpenWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    var body: some Scene {
        Window("OpenWhisper", id: "main") {
            MainWindowView(appState: appState)
        }
        .defaultSize(width: 620, height: 500)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updaterController.updater.checkForUpdates()
                }
            }
        }
        MenuBarExtra {
            MenuBarMenuView(appState: appState, updater: updaterController.updater)
        } label: {
            Image(systemName: appState.isRecording ? "record.circle" : "waveform")
        }
    }
}
