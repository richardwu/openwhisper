import AppKit
import Carbon.HIToolbox

@MainActor
final class RealtimePasteService {
    private(set) var lastTypedCount: Int = 0

    var hasTypedText: Bool {
        lastTypedCount > 0
    }

    func updateText(_ newText: String) {
        // Step 1: Select previously typed text (if any)
        if lastTypedCount > 0 {
            selectCharacters(count: lastTypedCount)
        }

        // Step 2: Type the new text character-by-character via CGEvent
        let utf16Units = Array(newText.utf16)
        let chunkSize = 8
        var offset = 0

        let source = CGEventSource(stateID: .hidSystemState)

        while offset < utf16Units.count {
            let end = min(offset + chunkSize, utf16Units.count)
            let chunk = Array(utf16Units[offset..<end])

            chunk.withUnsafeBufferPointer { buffer in
                guard let ptr = buffer.baseAddress else { return }

                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
                keyDown?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: ptr)
                keyDown?.post(tap: .cghidEventTap)

                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                keyUp?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: ptr)
                keyUp?.post(tap: .cghidEventTap)
            }

            offset = end

            if offset < utf16Units.count {
                usleep(1000)
            }
        }

        // Step 3: Update tracked count (use Character count, not UTF-16,
        // because Shift+Left arrow moves by grapheme cluster)
        lastTypedCount = newText.count
    }

    func selectCurrentText() {
        if lastTypedCount > 0 {
            selectCharacters(count: lastTypedCount)
        }
    }

    func reset() {
        lastTypedCount = 0
    }

    // MARK: - Private

    private func selectCharacters(count: Int) {
        let source = CGEventSource(stateID: .hidSystemState)

        // For large selections, use Shift+Cmd+Up as a shortcut
        if count > 100 {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x7E), keyDown: true)
            keyDown?.flags = [.maskShift, .maskCommand]
            keyDown?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x7E), keyDown: false)
            keyUp?.flags = [.maskShift, .maskCommand]
            keyUp?.post(tap: .cghidEventTap)

            usleep(500)
            return
        }

        for i in 0..<count {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x7B), keyDown: true)
            keyDown?.flags = .maskShift
            keyDown?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x7B), keyDown: false)
            keyUp?.flags = .maskShift
            keyUp?.post(tap: .cghidEventTap)

            // Small delay between groups of selection events for reliability
            if (i + 1) % 10 == 0 {
                usleep(500)
            }
        }
    }
}
