import SwiftUI
import KeyboardShortcuts
import SwiftWhisper

struct SettingsTabView: View {
    @Bindable var appState: AppState
    @State private var micAuthorized = false
    @State private var accessibilityGranted = false
    @State private var appleLanguageOptions: [WhisperLanguage] = [.english]

    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Hotkeys") {
                Picker("Recording Mode", selection: $appState.recordingTriggerMode) {
                    ForEach(RecordingTriggerMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .accessibilityIdentifier("settings.recordingMode")
                LabeledContent("Recording Shortcut") {
                    ShortcutRecorder(name: .toggleRecording)
                }
                LabeledContent("Cancel Recording") {
                    ShortcutRecorder(name: .cancelRecording)
                }
            }

            Section("Model") {
                LabeledContent("Voice Model") {
                    VoiceModelPicker(modelManager: appState.modelManager)
                }

                Picker("Language", selection: Binding(
                    get: { appState.modelManager.selectedLanguage },
                    set: { appState.modelManager.selectedLanguage = $0 }
                )) {
                    ForEach(languageOptions, id: \.self) { language in
                        Text(language.settingsDisplayName).tag(language)
                    }
                }
                .accessibilityIdentifier("settings.language")

                if appState.modelManager.isModelReady {
                    Label("\(appState.modelManager.selectedBackend.statusName), model ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("settings.modelStatus")
                } else if !appState.modelManager.selectedBackend.requiresModel {
                    Label("\(appState.modelManager.selectedBackend.statusName) is unavailable on this Mac", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
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
        if appState.modelManager.selectedBackend.isEnglishOnly {
            return [.english]
        }
        if appState.modelManager.selectedBackend == .appleStreaming {
            return appleLanguageOptions
        }
        if let supported = appState.modelManager.selectedBackend.supportedLanguageOptions {
            return supported
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

private struct VoiceModelPicker: View {
    let modelManager: ModelManager
    @State private var isPresented = false
    @State private var query = ""

    /// Apple first, then streaming models, then batch models; each group by
    /// descending accuracy, with ties going to the faster model.
    private static let ordered = TranscriptionBackend.allCases.sorted { a, b in
        func key(_ backend: TranscriptionBackend) -> (Int, Int, Int) {
            let group = backend == .appleStreaming ? 0 : backend.isStreamingBackend ? 1 : 2
            return (group, -(backend.scores?.accuracy ?? 0), -(backend.scores?.speed ?? 0))
        }
        return key(a) < key(b)
    }

    private var filtered: [TranscriptionBackend] {
        Self.ordered.filter {
            query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            // Mirrors the native grouped-form menu picker (e.g. Language).
            HStack(spacing: 11) {
                HStack(spacing: 6) {
                    ModelIcon(backend: modelManager.selectedBackend, size: 16)
                    Text(modelManager.selectedBackend.statusName)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Color.primary.opacity(0.1), in: Circle())
            }
            .foregroundStyle(.primary)
            .padding(.trailing, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.modelPicker")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("", text: $query, prompt: Text("Search models"))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("settings.modelSearch")
                }
                .padding(10)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered, id: \.self) { backend in
                            row(backend)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 300)
                Divider()
                HStack(spacing: 12) {
                    Label("Accuracy", systemImage: ScoreMetric.accuracyIcon)
                    Label("Speed", systemImage: ScoreMetric.speedIcon)
                    Spacer()
                    Text("Relative scores")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .help("Benchmark scores from Handy's model catalog, out of 100. Accuracy is not % correct; speed was measured on a PC, not this Mac.")
            }
            .frame(width: 360)
        }
    }

    private func row(_ backend: TranscriptionBackend) -> some View {
        let isSelected = backend == modelManager.selectedBackend
        let isLocal = modelManager.isAvailableLocally(backend)
        return Button {
            modelManager.selectBackend(backend)
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                ModelIcon(backend: backend)
                VStack(alignment: .leading, spacing: 1) {
                    Text(backend.statusName)
                    if let detail = backend.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer()
                if let scores = backend.scores {
                    HStack(spacing: 8) {
                        ScoreMetric(icon: ScoreMetric.accuracyIcon, value: scores.accuracy)
                        ScoreMetric(icon: ScoreMetric.speedIcon, value: scores.speed)
                    }
                    .help("Accuracy \(scores.accuracy)/100, speed \(scores.speed)/100")
                } else if backend == .appleStreaming && !isLocal {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Fixed slot keeps the score columns aligned whether or not a row shows an icon.
                ZStack {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    } else if !isLocal && backend != .appleStreaming {
                        Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.model.\(backend.rawValue)")
        .disabled(backend == .appleStreaming && !isLocal)
    }
}

/// Compact icon + score, fixed width so values line up across rows.
private struct ScoreMetric: View {
    static let accuracyIcon = "scope"
    static let speedIcon = "bolt.fill"
    let icon: String
    let value: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text("\(value)")
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .frame(width: 38, alignment: .leading)
    }
}

private struct ModelIcon: View {
    let backend: TranscriptionBackend
    var size: CGFloat = 22

    private var isApple: Bool { backend == .appleStreaming }

    var body: some View {
        Image(systemName: isApple ? "apple.logo" : "waveform")
            .font(.system(size: size * (isApple ? 0.55 : 0.5), weight: .semibold))
            .foregroundStyle(.white)
            // The Apple glyph sits low in its bounding box; nudge it to optical center.
            .offset(y: isApple ? -size / 44 : 0)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: isApple
                        ? [Color(white: 0.32), Color(white: 0.1)]
                        : [Color(red: 0.49, green: 0.42, blue: 1.0), Color(red: 0.36, green: 0.27, blue: 0.9)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            )
    }
}

private extension TranscriptionBackend {
    /// Parenthesized part of `displayName`, e.g. "148 MB, batch".
    var detail: String? {
        guard let start = displayName.firstIndex(of: "(") else { return nil }
        return String(displayName[displayName.index(after: start)...].dropLast())
    }
}
