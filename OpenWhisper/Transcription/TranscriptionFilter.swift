import Foundation

enum TranscriptionFilter {
    static func filter(_ text: String) -> String {
        var result = text
        // Remove <|...|> special tokens
        result = result.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        // Remove [BRACKET_TAGS] - matches [BLANK_AUDIO], [MUSIC], [inaudible], etc.
        result = result.replacingOccurrences(of: "\\[\\w[\\w\\s]*\\]", with: "", options: .regularExpression)
        // Remove (PAREN_TAGS) - matches (music), (inaudible), (SPEAKING FOREIGN LANGUAGE), etc.
        result = result.replacingOccurrences(of: "\\([A-Za-z][A-Za-z\\s]*\\)", with: "", options: .regularExpression)
        // Remove musical note sequences
        result = result.replacingOccurrences(of: "♪+", with: "", options: .regularExpression)
        // Collapse multiple spaces and trim
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Filter common hallucinated phrases when they're the entire output
        let hallucinatedPhrases = [
            "thank you for watching",
            "thank you for listening",
            "thanks for watching",
            "thanks for listening",
        ]
        if hallucinatedPhrases.contains(result.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            return ""
        }
        return result
    }
}
