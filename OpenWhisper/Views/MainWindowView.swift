import SwiftUI

enum AppTab: String, CaseIterable {
    case home = "Home"
    case settings = "Settings"
    case history = "History"

    var icon: String {
        switch self {
        case .home: return "house"
        case .settings: return "gear"
        case .history: return "clock"
        }
    }
}

struct MainWindowView: View {
    let appState: AppState
    @State private var selectedTab: AppTab = .home
    @State private var micAuthorized = Permissions.isMicrophoneAuthorized
    @State private var accessibilityGranted = Permissions.isAccessibilityGranted

    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(AppTab.allCases, id: \.self, selection: $selectedTab) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                }
                .navigationSplitViewColumnWidth(min: 150, ideal: 160, max: 180)
            } detail: {
                Group {
                    switch selectedTab {
                    case .home:
                        homeTab
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

                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 580, maxWidth: 700, minHeight: 420, maxHeight: 640)
        .onReceive(permissionTimer) { _ in
            micAuthorized = Permissions.isMicrophoneAuthorized
            accessibilityGranted = Permissions.isAccessibilityGranted
        }
        .onAppear {
            micAuthorized = Permissions.isMicrophoneAuthorized
            accessibilityGranted = Permissions.isAccessibilityGranted
        }
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

    private var homeTab: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)

                    Text("OpenWhisper")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Voice-to-text, locally and privately")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)
                .padding(.bottom, 12)

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
                                Permissions.requestMicrophone()
                            }
                        }

                        if !accessibilityGranted {
                            permissionBanner(
                                icon: "lock.shield",
                                title: "Accessibility Access Required",
                                description: "Accessibility access is required to paste transcribed text and for the global hotkey to work in all apps.",
                                buttonLabel: "Open Accessibility Settings"
                            ) {
                                Permissions.openAccessibilitySettings()
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
                        title: "Press your hotkey to start recording",
                        detail: "Press again to stop and transcribe"
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
