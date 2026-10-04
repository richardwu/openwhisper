import XCTest
@testable import OpenWhisper

final class BundledVocabularyCoverageTests: XCTestCase {
    func testBundleCoversCodingAndKnowledgeWorkTerms() {
        let terms = Set(VocabularyStore.bundledTerms)
        for expected in [
            "OpenWhisper", "SwiftUI", "PostgreSQL", "ChatGPT",
            "MCP", "OAuth", "KPI", "TL;DR", "NYSE", "NASDAQ"
        ] {
            XCTAssertTrue(terms.contains(expected), "Missing bundled term: \(expected)")
        }
    }

    func testBundledTermsHaveNoDuplicateSpellings() {
        let terms = VocabularyStore.bundledTerms
        XCTAssertEqual(Set(terms).count, terms.count)
    }
}
