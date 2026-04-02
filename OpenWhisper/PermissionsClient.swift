import AVFoundation
import AppKit

/// Injectable permissions checker replacing the static `Permissions` enum.
@MainActor
@Observable
final class PermissionsClient {
    enum Mode {
        case live
        case mock(microphone: Bool, accessibility: Bool)
    }

    private let mode: Mode

    init(mode: Mode = .live) {
        self.mode = mode
    }

    var isMicrophoneAuthorized: Bool {
        switch mode {
        case .live:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .mock(let mic, _):
            return mic
        }
    }

    var isAccessibilityGranted: Bool {
        switch mode {
        case .live:
            return AXIsProcessTrustedWithOptions(nil)
        case .mock(_, let acc):
            return acc
        }
    }

    var allGranted: Bool {
        isMicrophoneAuthorized && isAccessibilityGranted
    }

    func requestMicrophone() {
        guard case .live = mode else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func promptAccessibilityIfNeeded() {
        guard case .live = mode else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard case .live = mode else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
