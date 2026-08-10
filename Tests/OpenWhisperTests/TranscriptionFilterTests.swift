import XCTest
@testable import OpenWhisper

@MainActor
final class TranscriptionFilterTests: XCTestCase {

    private var service: TranscriptionService!

    override func setUp() {
        super.setUp()
        service = TranscriptionService(mode: .stub(result: ""))
    }

    func testRemovesSpecialTokens() {
        let result = service.filterTranscription("<|en|> Hello <|endoftext|>")
        XCTAssertEqual(result, "Hello")
    }

    func testRemovesBracketTags() {
        let result = service.filterTranscription("[BLANK_AUDIO] Hello [MUSIC]")
        XCTAssertEqual(result, "Hello")
    }

    func testRemovesParenTags() {
        let result = service.filterTranscription("(music) Hello (inaudible)")
        XCTAssertEqual(result, "Hello")
    }

    func testRemovesMusicalNotes() {
        let result = service.filterTranscription("♪♪♪ Hello ♪")
        XCTAssertEqual(result, "Hello")
    }

    func testCollapsesWhitespace() {
        let result = service.filterTranscription("  Hello   world  ")
        XCTAssertEqual(result, "Hello world")
    }

    func testFiltersHallucinatedPhrases() {
        XCTAssertEqual(service.filterTranscription("Thank you for watching."), "")
        XCTAssertEqual(service.filterTranscription("thanks for listening"), "")
        XCTAssertEqual(service.filterTranscription("Thank you for watching!"), "")
    }

    func testPreservesRealContent() {
        let result = service.filterTranscription("This is a real transcription.")
        XCTAssertEqual(result, "This is a real transcription.")
    }

    func testPunctuationOnlyReturnEmpty() {
        XCTAssertEqual(service.filterTranscription("."), "")
        XCTAssertEqual(service.filterTranscription("..."), "")
        XCTAssertEqual(service.filterTranscription(". ."), "")
    }

    func testEmptyInput() {
        XCTAssertEqual(service.filterTranscription(""), "")
        XCTAssertEqual(service.filterTranscription("   "), "")
    }
}
