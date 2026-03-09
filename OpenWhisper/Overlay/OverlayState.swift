import Foundation

@MainActor
@Observable
final class OverlayState {
    enum Phase {
        case hidden
        case recording
        case transcribing
        case cancelled
        case modelDownloading
        case accessibilityRequired
    }

    var phase: Phase = .hidden
    var partialTranscription: String = ""
}
