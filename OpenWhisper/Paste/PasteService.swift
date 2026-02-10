import AppKit
import Carbon.HIToolbox

@MainActor
final class PasteService {
    func paste(text: String) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let previousContents = pasteboard.pasteboardItems?.compactMap { item -> (String, Data)? in
            guard let type = item.types.first,
                  let data = item.data(forType: type) else { return nil }
            return (type.rawValue, data)
        }
        let previousChangeCount = pasteboard.changeCount

        // Set transcribed text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        simulatePaste()

        // Restore clipboard after a delay
        let saved = previousContents
        let savedChangeCount = previousChangeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Only restore if our paste is still on the clipboard
            if pasteboard.changeCount == savedChangeCount + 1 {
                pasteboard.clearContents()
                if let saved {
                    for (typeRaw, data) in saved {
                        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(typeRaw))
                    }
                }
            }
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
