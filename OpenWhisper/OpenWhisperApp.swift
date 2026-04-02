import Sparkle
import SwiftUI

@main
struct OpenWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let appState: AppState
    private let updaterController: SPUStandardUpdaterController?

    init() {
        let config = LaunchConfiguration.current

        let environment: AppEnvironment
        if config.isTestMode, let scenario = config.testScenario {
            let suiteName = config.defaultsSuiteName ?? "com.openwhisper.test.\(UUID().uuidString)"
            environment = .test(scenario: scenario, suiteName: suiteName)
        } else {
            environment = .live(config)
        }

        self.appState = AppState(environment: environment)

        if config.disableSparkle {
            self.updaterController = nil
        } else {
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
            )
        }
    }

    var body: some Scene {
        Window(AppIdentity.displayName, id: AppIdentity.mainWindowID) {
            MainWindowView(appState: appState)
        }
        .defaultSize(width: 620, height: 525)
        .commands {
            CommandGroup(after: .appInfo) {
                if let updater = updaterController?.updater {
                    Button("Check for Updates...") {
                        updater.checkForUpdates()
                    }
                }
            }
        }
        MenuBarExtra {
            MenuBarMenuView(appState: appState, updater: updaterController?.updater)
        } label: {
            Image(systemName: appState.isRecording ? "record.circle" : "waveform")
        }
    }
}
