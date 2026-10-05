import AppKit
import SwiftUI
import XCTest
@testable import OpenWhisper

@MainActor
final class VocabularyLayoutTests: XCTestCase {
    func testEmptyVocabularyKeepsSplitPaneWithinWindow() async throws {
        try await assertSplitPaneFits(tab: .vocabulary)
    }

    func testPinnedVocabularyKeepsSplitPaneWithinWindow() async throws {
        try await assertSplitPaneFits(tab: .vocabulary, pinnedTerms: "AcmeDB, NimbusCache")
    }

    func testEmptyHistoryKeepsSplitPaneWithinWindow() async throws {
        try await assertSplitPaneFits(tab: .history)
    }

    func testSettingsKeepsSplitPaneWithinWindow() async throws {
        try await assertSplitPaneFits(tab: .settings)
    }

    private func assertSplitPaneFits(
        tab: AppTab,
        pinnedTerms: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let suiteName = "com.openwhisper.test.layout.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let state = AppState(environment: .test(scenario: .launchReadyState, suiteName: suiteName))
        if let pinnedTerms {
            XCTAssertEqual(state.transcriptionService.learnVocabularyTerms(pinnedTerms).count, 2)
        }

        for size in [NSSize(width: 620, height: 640), NSSize(width: 580, height: 420), NSSize(width: 700, height: 1000)] {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }

            let host = NSHostingView(rootView: MainWindowView(appState: state, initialTab: tab))
            window.contentView = host
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            // AppKit installs the split columns on the next run-loop turn.
            // The window remains hidden and never takes keyboard or mouse focus.
            try await Task.sleep(nanoseconds: 50_000_000)
            host.layoutSubtreeIfNeeded()

            XCTAssertFalse(window.isVisible, file: file, line: line)
            let split = try XCTUnwrap(firstSplitView(in: host), file: file, line: line)
            let paneBounds = host.convert(split.bounds, from: split)
            let context = "\(tab.rawValue), \(Int(size.width)) × \(Int(size.height))"
            XCTAssertLessThanOrEqual(
                paneBounds.height, host.bounds.height + 1,
                "The split pane must leave the footer inside the window: \(context)",
                file: file, line: line
            )
            XCTAssertGreaterThanOrEqual(
                paneBounds.minY, host.bounds.minY - 1,
                "The split pane must not push its header or sidebar above the window: \(context)",
                file: file, line: line
            )
            XCTAssertLessThanOrEqual(
                paneBounds.maxY, host.bounds.maxY + 1,
                "The split pane must not extend below the window: \(context)",
                file: file, line: line
            )
            XCTAssertGreaterThan(
                paneBounds.height, host.bounds.height - 60,
                "The split pane must grow with the window, leaving only the footer: \(context)",
                file: file, line: line
            )
        }
    }

    private func firstSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let split = firstSplitView(in: child) { return split }
        }
        return nil
    }
}
