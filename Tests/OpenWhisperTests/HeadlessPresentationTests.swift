import AppKit
import XCTest
@testable import OpenWhisper

@MainActor
final class HeadlessPresentationTests: XCTestCase {
    func testRecordingKeepsWindowsAndOverlaysHidden() async throws {
        try requireHeadlessHost()
        let suite = "com.openwhisper.test.headless.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let state = AppState(environment: .test(scenario: .recordToTranscribeSuccess, suiteName: suite))

        await state.toggleRecording()
        XCTAssertTrue(state.isRecording)
        XCTAssertNil(state.overlayController)
        XCTAssertFalse(NSApp.windows.contains(where: \.isVisible))
        await state.toggleRecording()

        XCTAssertEqual(state.pasteService.pastedTexts, ["Hello world"])
        XCTAssertEqual(state.historyStore.entries.first?.text, "Hello world")
        XCTAssertFalse(NSApp.windows.contains(where: \.isVisible))
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
    }

    func testPermissionRecoveryDoesNotActivateTheApp() async throws {
        try requireHeadlessHost()
        let suite = "com.openwhisper.test.headless-permission.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let state = AppState(environment: .test(scenario: .micDenied, suiteName: suite))

        await state.toggleRecording()
        AppState.showMainWindow()

        XCTAssertEqual(state.statusMessage, "Microphone permission required")
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
        XCTAssertFalse(NSApp.windows.contains(where: \.isVisible))
    }

    private func requireHeadlessHost() throws {
        guard LaunchConfiguration.current.isHeadlessTest else {
            throw XCTSkip("Run scripts/test_background.sh to verify headless presentation")
        }
    }
}
