import Foundation

@MainActor
@Observable
final class OverlayState {
    enum Phase {
        case hidden
        case recording
        case transcribing
        case cancelled
    }

    var phase: Phase = .hidden
}
