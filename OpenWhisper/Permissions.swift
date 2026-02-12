import AVFoundation
import AppKit

enum Permissions {
    static var isMicrophoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    static func promptAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static var allGranted: Bool {
        isMicrophoneAuthorized && isAccessibilityGranted
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
