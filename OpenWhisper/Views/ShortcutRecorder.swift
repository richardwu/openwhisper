import SwiftUI
import KeyboardShortcuts
import Carbon.HIToolbox

/// A custom shortcut recorder that allows capturing Escape and other keys
/// that the built-in KeyboardShortcuts.Recorder intercepts.
struct ShortcutRecorder: View {
    let name: KeyboardShortcuts.Name
    @State private var isRecording = false
    @State private var currentShortcut: KeyboardShortcuts.Shortcut?
    @State private var eventMonitor: Any?

    var body: some View {
        HStack {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(displayText)
                    .frame(minWidth: 80)
            }
            .buttonStyle(.bordered)

            if currentShortcut != nil, !isRecording {
                Button {
                    KeyboardShortcuts.setShortcut(nil, for: name)
                    currentShortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            currentShortcut = KeyboardShortcuts.getShortcut(for: name) ?? name.defaultShortcut
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var displayText: String {
        if isRecording {
            return "Press a key..."
        }
        if let shortcut = currentShortcut {
            return shortcutDisplayString(shortcut)
        }
        return "Record Shortcut"
    }

    private func startRecording() {
        isRecording = true
        // Temporarily disable the shortcut so it doesn't fire while we record a new one
        KeyboardShortcuts.disable(name)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = KeyboardShortcuts.Key(rawValue: Int(event.keyCode))
            let shortcut = KeyboardShortcuts.Shortcut(key, modifiers: modifiers)
            KeyboardShortcuts.setShortcut(shortcut, for: name)
            currentShortcut = shortcut
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        // Re-enable the shortcut
        KeyboardShortcuts.enable(name)
    }

    private func shortcutDisplayString(_ shortcut: KeyboardShortcuts.Shortcut) -> String {
        var parts: [String] = []
        let mods = shortcut.modifiers
        if mods.contains(.control) { parts.append("\u{2303}") }
        if mods.contains(.option) { parts.append("\u{2325}") }
        if mods.contains(.shift) { parts.append("\u{21E7}") }
        if mods.contains(.command) { parts.append("\u{2318}") }

        if let key = shortcut.key {
            parts.append(keyDisplayString(key))
        }

        return parts.joined()
    }

    private func keyDisplayString(_ key: KeyboardShortcuts.Key) -> String {
        switch key {
        case .escape: return "\u{238B}"
        case .return: return "\u{21A9}"
        case .tab: return "\u{21E5}"
        case .space: return "\u{2423}"
        case .delete: return "\u{232B}"
        case .deleteForward: return "\u{2326}"
        case .upArrow: return "\u{2191}"
        case .downArrow: return "\u{2193}"
        case .leftArrow: return "\u{2190}"
        case .rightArrow: return "\u{2192}"
        case .home: return "\u{2196}"
        case .end: return "\u{2198}"
        case .pageUp: return "\u{21DE}"
        case .pageDown: return "\u{21DF}"
        default:
            let keyCode = UInt16(key.rawValue)
            let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            guard let layoutDataRef else {
                return "Key(\(key.rawValue))"
            }
            let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self)
            let keyLayoutPtr = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0
            let status = UCKeyTranslate(
                keyLayoutPtr,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            if status == noErr, length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
            return "Key(\(key.rawValue))"
        }
    }
}
