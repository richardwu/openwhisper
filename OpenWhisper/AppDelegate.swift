import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppState.showMainWindow()
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Monitor window visibility to hide/show dock icon
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func windowDidClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              !(window is NSPanel),
              window.title == "OpenWhisper" || window.identifier?.rawValue == "main"
        else { return }

        // Short delay to let the window fully close
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let hasVisibleMainWindow = NSApplication.shared.windows.contains {
                !($0 is NSPanel) && $0.isVisible &&
                ($0.title == "OpenWhisper" || $0.identifier?.rawValue == "main")
            }
            if !hasVisibleMainWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              !(window is NSPanel),
              window.title == "OpenWhisper" || window.identifier?.rawValue == "main"
        else { return }
        NSApp.setActivationPolicy(.regular)
    }
}
