import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    private var panel: RecordingOverlayPanel?
    private let overlayState: OverlayState
    private let audioRecorder: AudioRecorder

    init(overlayState: OverlayState, audioRecorder: AudioRecorder) {
        self.overlayState = overlayState
        self.audioRecorder = audioRecorder
    }

    func show() {
        if panel != nil { return }

        let panelWidth: CGFloat = 280
        let panelHeight: CGFloat = 80

        // Position at bottom-center of the screen containing the mouse cursor
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]

        let x = screen.frame.midX - panelWidth / 2
        let y = screen.visibleFrame.minY + 40

        let frame = NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
        let panel = RecordingOverlayPanel(contentRect: frame)

        let hostingView = NSHostingView(
            rootView: RecordingOverlayContent(
                overlayState: overlayState,
                audioRecorder: audioRecorder
            )
        )
        panel.contentView = hostingView
        panel.orderFront(nil)
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}
