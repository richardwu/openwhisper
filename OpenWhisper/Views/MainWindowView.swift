import AppKit
import SwiftUI
import KeyboardShortcuts

enum AppTab: String, CaseIterable {
    case home = "Home"
    case history = "History"
    case vocabulary = "Vocabulary"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .home: return "house"
        case .vocabulary: return "text.book.closed"
        case .settings: return "gear"
        case .history: return "clock"
        }
    }
}

struct MainWindowView: View {
    let appState: AppState
    @State private var selectedTab: AppTab = .home
    @State private var micAuthorized = false
    @State private var accessibilityGranted = false
    @State private var copiedLatestTranscription = false

    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(appState: AppState, initialTab: AppTab = .home) {
        self.appState = appState
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(AppTab.allCases, id: \.self, selection: $selectedTab) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .accessibilityIdentifier("navigation.\(String(describing: tab))")
                }
                .navigationSplitViewColumnWidth(min: 150, ideal: 160, max: 180)
            } detail: {
                Group {
                    switch selectedTab {
                    case .home:
                        homeTab
                    case .vocabulary:
                        VocabularyTabView(appState: appState)
                    case .settings:
                        SettingsTabView(appState: appState)
                    case .history:
                        HistoryView(historyStore: appState.historyStore)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Status bar
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .opacity(appState.isRecording || appState.isTranscribing ? 1.0 : 0.8)

                Text(footerStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("footer.status")

                Spacer()

                if !appState.modelManager.isModelReady {
                    if appState.modelManager.isDownloading {
                        ProgressView()
                            .controlSize(.mini)
                        Text("\(Int(appState.modelManager.downloadProgress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Model not ready")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                if canCopyLatestTranscription {
                    Button {
                        copyLatestTranscription()
                    } label: {
                        Image(systemName: copiedLatestTranscription ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(copiedLatestTranscription ? .green : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(copiedLatestTranscription ? "Latest transcription copied" : "Copy latest transcription")
                    .help("Copy latest transcription")
                    .accessibilityIdentifier("footer.copy")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 580, idealWidth: 620, maxWidth: 700, minHeight: 420, idealHeight: 640, maxHeight: .infinity)
        .onReceive(permissionTimer) { _ in
            refreshPermissions()
        }
        .onAppear {
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        micAuthorized = appState.permissionsClient.isMicrophoneAuthorized
        accessibilityGranted = appState.permissionsClient.isAccessibilityGranted
    }

    private var statusColor: Color {
        if appState.isRecording {
            return .red
        } else if appState.isTranscribing {
            return .orange
        } else {
            return .green
        }
    }

    private var canCopyLatestTranscription: Bool {
        appState.historyStore.entries.first != nil
    }

    private var footerStatusMessage: String {
        guard appState.statusMessage == "Ready",
              let latestText = appState.historyStore.entries.first?.text else {
            return appState.statusMessage
        }

        let preview = String(latestText.prefix(50))
        return "Latest: \(preview)\(latestText.count > 50 ? "..." : "")"
    }

    private func copyLatestTranscription() {
        guard let text = appState.historyStore.entries.first?.text else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { return }

        copiedLatestTranscription = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedLatestTranscription = false
        }
    }

    private var homeTab: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)

                    Text(AppIdentity.displayName)
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Voice-to-text, locally and privately")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)
                .padding(.bottom, 12)

                if appState.isTestMode {
                    HStack {
                        Button(appState.isRecording ? "Stop Recording" : "Start Recording") {
                            Task { await appState.toggleRecording() }
                        }
                        .accessibilityIdentifier("recording.toggle")
                        Button("Cancel Recording") { appState.cancelRecording() }
                            .disabled(!appState.isRecording)
                            .accessibilityIdentifier("recording.cancel")
                    }
                    .padding(.bottom, 12)
                }

                // Permission banners
                if !micAuthorized || !accessibilityGranted {
                    VStack(spacing: 8) {
                        if !micAuthorized {
                            permissionBanner(
                                icon: "mic.slash.fill",
                                title: "Microphone Access Required",
                                description: "Microphone access is required to record your voice.",
                                buttonLabel: "Grant Microphone Access"
                            ) {
                                appState.permissionsClient.requestMicrophone()
                            }
                        }

                        if !accessibilityGranted {
                            permissionBanner(
                                icon: "lock.shield",
                                title: "Accessibility Access Required",
                                description: "Accessibility access is required to paste transcribed text and for the global hotkey to work in all apps.",
                                buttonLabel: "Open Accessibility Settings"
                            ) {
                                appState.permissionsClient.openAccessibilitySettings()
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }

                Divider()

                // Instructions
                VStack(alignment: .leading, spacing: 12) {
                    instructionRow(
                        step: 1,
                        title: appState.recordingTriggerMode.instructionTitle,
                        detail: appState.recordingTriggerMode.instructionDetail
                    )
                    instructionRow(
                        step: 2,
                        title: "Text is pasted automatically",
                        detail: "Transcribed text is typed into your active text field"
                    )
                    instructionRow(
                        step: 3,
                        title: "Runs in your menu bar",
                        detail: "Look for the waveform icon in the menu bar"
                    )
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

                // Hotkey reference
                Divider()

                HStack(spacing: 24) {
                    hotkeyLabel(appState.recordingTriggerMode == .toggle ? "Start/stop" : "Hold to record", for: .toggleRecording)
                    hotkeyLabel("Cancel recording", for: .cancelRecording)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
        }
    }

    private func permissionBanner(
        icon: String,
        title: String,
        description: String,
        buttonLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(buttonLabel, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func hotkeyLabel(_ label: String, for name: KeyboardShortcuts.Name) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            let shortcutText = KeyboardShortcuts.getShortcut(for: name)?.displayString
                ?? name.defaultShortcut?.displayString
                ?? "Not set"
            Text(shortcutText)
                .font(.caption.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func instructionRow(step: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(step)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.quaternary))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
