import AppKit
import SwiftUI
import XCTest
import Vision
@testable import OpenWhisper

@MainActor
final class RecordingOverlayTests: XCTestCase {
    func testRecordingTransitionsToProcessingInHiddenWindow() async throws {
        let state = OverlayState()
        let recorder = AudioRecorder(mode: .fixture(samples: [0.1]))
        try recorder.startRecording()
        state.phase = .recording

        let size = NSSize(width: 280, height: 80)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: RecordingOverlayContent(overlayState: state, audioRecorder: recorder))
        window.contentView = host
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        host.layoutSubtreeIfNeeded()

        XCTAssertFalse(window.isVisible)
        XCTAssertNil(firstProgressIndicator(in: host))
        XCTAssertNil(accessibilityElement(withIdentifier: "overlay.processing.label", in: host))

        _ = recorder.stopRecording()
        state.phase = .transcribing
        try await Task.sleep(nanoseconds: 50_000_000)
        host.layoutSubtreeIfNeeded()

        XCTAssertFalse(window.isVisible, "Overlay checks must never present a window or take focus")
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let context = workspace.appendingPathComponent(".context", isDirectory: true)
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        try png.write(to: context.appendingPathComponent("processing-overlay.png"))

        if let spinner = firstProgressIndicator(in: host) {
            XCTAssertEqual(spinner.style, .spinning)
            XCTAssertTrue(spinner.isIndeterminate)
        } else {
            // SwiftUI may render ProgressView without an AppKit control.
            let spinner = try XCTUnwrap(accessibilityElement(withIdentifier: "overlay.processing.spinner", in: host))
            XCTAssertEqual(spinner.accessibilityRole(), .progressIndicator)
        }
        if let label = accessibilityElement(withIdentifier: "overlay.processing.label", in: host) {
            XCTAssertEqual((label.accessibilityValue() as? String) ?? label.accessibilityLabel(), "Processing...")
        } else {
            // Hidden SwiftUI windows can omit static text from Accessibility.
            // Verify the actual rendered label with on-device text recognition.
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
            let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
            XCTAssertTrue(text.contains("Processing"), "The rendered overlay label is missing: \(text)")
        }
        XCTAssertFalse(window.isVisible)
    }

    private func firstProgressIndicator(in view: NSView) -> NSProgressIndicator? {
        if let progress = view as? NSProgressIndicator { return progress }
        for child in view.subviews {
            if let progress = firstProgressIndicator(in: child) { return progress }
        }
        return nil
    }

    private func accessibilityElement(withIdentifier identifier: String, in object: Any) -> (any NSAccessibilityProtocol)? {
        guard let element = object as? any NSAccessibilityProtocol else { return nil }
        if element.accessibilityIdentifier() == identifier { return element }
        for child in element.accessibilityChildren() ?? [] {
            if let found = accessibilityElement(withIdentifier: identifier, in: child) { return found }
        }
        return nil
    }
}
