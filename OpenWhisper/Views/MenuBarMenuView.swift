import KeyboardShortcuts
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

        recordingButton

        Divider()

        Button("Check for Updates...") {
            updater.checkForUpdates()
        }

        Button("Show Main Window") {
            AppState.showMainWindow()
        }

        Divider()

        Button("Quit OpenWhisper") {
            NSApplication.shared.terminate(nil)
        }
    }

    @ViewBuilder
    private var recordingButton: some View {
        let button = Button(appState.isRecording ? "Stop Recording" : "Start Recording") {
            Task {
                await appState.toggleRecording()
            }
        }
        .disabled(!appState.modelManager.isModelReady || appState.isTranscribing)

        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording),
           let keyEquiv = shortcut.swiftUIKeyEquivalent {
            button.keyboardShortcut(keyEquiv, modifiers: shortcut.swiftUIModifiers)
        } else {
            button
        }
    }
}

@MainActor
private extension KeyboardShortcuts.Shortcut {
    var swiftUIKeyEquivalent: KeyEquivalent? {
        guard let str = nsMenuItemKeyEquivalent, let char = str.first else { return nil }
        return KeyEquivalent(char)
    }

    var swiftUIModifiers: EventModifiers {
        var mods: EventModifiers = []
        if modifiers.contains(.command) { mods.insert(.command) }
        if modifiers.contains(.option) { mods.insert(.option) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        if modifiers.contains(.control) { mods.insert(.control) }
        return mods
    }
}
