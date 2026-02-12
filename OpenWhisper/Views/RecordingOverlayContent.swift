import SwiftUI

struct RecordingOverlayContent: View {
    let overlayState: OverlayState
    let audioRecorder: AudioRecorder

    var body: some View {
        Group {
            switch overlayState.phase {
            case .hidden:
                EmptyView()
            case .recording:
                recordingView
            case .transcribing:
                transcribingView
            case .cancelled:
                cancelledView
            case .accessibilityRequired:
                accessibilityRequiredView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recordingView: some View {
        HStack(spacing: 12) {
            // Pulsing red dot
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .modifier(PulsingModifier())

            WaveformView(levels: audioRecorder.recentLevels)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }

    private var cancelledView: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.8))

            Text("Recording Cancelled")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }

    private var accessibilityRequiredView: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.red.opacity(0.9))

            Text("Enable Accessibility in System Settings")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }

    private var transcribingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)

            Text("Transcribing...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }
}

private struct PulsingModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
