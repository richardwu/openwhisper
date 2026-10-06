import Foundation

/// Local vocabulary used to bias Whisper toward coding and knowledge-work terms.
///
/// The bundled terms are deliberately kept in source so an app release contains
/// the exact list that was tested. Learned terms are stored as small records in
/// UserDefaults. This type does not inspect projects, focused applications,
/// clipboard contents, or keyboard events.
final class VocabularyStore {
    struct LearnedTerm: Codable, Equatable {
        let term: String
        var count: Int
        var lastLearned: Date

        init(term: String, count: Int = 1, lastLearned: Date = Date()) {
            self.term = term
            self.count = count
            self.lastLearned = lastLearned
        }
    }

    /// The order is intentional. Terms near the start are more likely to fit
    /// when the prompt character budget is reached.
    static let bundledTerms: [String] = [
        // High-value terms that should be available in the default prompt.
        "OpenWhisper", "SwiftUI", "PostgreSQL", "ChatGPT", "Claude", "OpenAI",
        "NYSE", "NASDAQ", "New York Stock Exchange",
        "post-crescue",
        "TypeScript", "Python", "JavaScript", "GitHub", "Docker", "JSON", "API",
        "SDK", "MCP", "OAuth", "LLM", "PRD", "RFC", "MVP", "OKR", "KPI", "ETA", "TL;DR",

        // OpenWhisper and local speech terms.
        "SwiftWhisper", "whisper.cpp", "WhisperKit", "FluidAudio",
        "Parakeet", "Nemotron", "SpeechAnalyzer", "SpeechTranscriber", "CoreML",
        "Metal", "Accelerate", "AVAudioEngine", "AudioUnit", "TCC",

        // Swift and Apple development.
        "Swift", "UIKit", "AppKit", "Xcode", "xcodebuild", "XCTest",
        "XcodeGen", "SPM", "Package.swift", "async/await", "AsyncStream",
        "MainActor", "Sendable", "Codable", "UserDefaults",

        // High-frequency coding terms and acronyms.
        "Rust", "Go", "React", "Next.js", "SQL", "YAML", "Git",
        "GraphQL", "REST", "CLI",

        // AI, product, and general knowledge-work terms. These appear before
        // the long coding list so the default prompt covers both coding and
        // general work within the same bounded context window.
        "Gemini", "Copilot", "Anthropic", "GPT-4o", "GPT-5",
        "Transformer", "tokenizer", "embedding", "machine learning", "fine-tuning",
        "inference", "latency", "benchmark", "regression", "A/B test",
        "ROI", "SLA", "ADR", "roadmap", "backlog", "sprint", "stand-up",
        "stakeholder", "FYI", "ASAP", "EOD", "WIP",
        "TBD", "FAQ", "IMO", "IRL", "POV", "TIL", "AFAIK", "FWIW", "OOO", "WFH", "PTO",
        "SME", "B2B", "B2C", "GTM", "ICP", "TAM", "SAM", "SOM", "NPS", "CSAT", "SLO", "SLI",
        "RACI", "DRI", "P0", "P1", "P2", "P3",

        // Common languages, runtimes, frameworks, and tools.
        "Kotlin", "Java", "C++", "C#", ".NET", "Dart", "Ruby", "PHP", "HTML", "CSS",
        "Node.js", "Deno", "Bun", "React Native", "Vue", "Svelte",
        "Angular", "Vite", "Webpack", "esbuild", "npm", "pnpm", "Yarn", "Cargo",
        "pip", "Homebrew", "Kubernetes", "k8s", "Terraform", "Ansible",
        "GitLab", "Bitbucket", "GitHub Actions", "CI/CD", "SSH",

        // Databases, APIs, infrastructure, and protocols.
        "Postgres", "MySQL", "SQLite", "MongoDB", "Redis", "DuckDB",
        "pgvector",
        "gRPC", "WebSocket", "HTTP", "HTTPS", "TCP", "DNS", "OAuth2",
        "OpenID Connect", "JWT", "TLS", "RAG", "NLP", "GPU", "CPU", "RAM", "VRAM",
        "API key", "x402",

        // Additional general-work terms remain available when a larger prompt
        // budget is configured or when a correction promotes a term.
        "Swift Package Manager", "Combine", "Observation", "Observable", "Task", "actor",
        "Core Data", "CloudKit", "StoreKit", "WidgetKit", "App Intents", "SiriKit",
        "Instruments", "TestFlight", "App Store Connect", "Info.plist", "entitlements",
        "project.yml", "Google", "vector database", "deep learning", "workflow", "knowledge base",
        "meeting notes", "action items", "follow-up", "calendar", "spreadsheet",
        "presentation", "Markdown", "PDF", "URL", "email", "FOMO",
        "i.e.", "e.g.", "etc.", "versus", "proprietary", "open source", "offline",
        "on-device", "privacy", "Accessibility", "macOS", "iOS", "Linux", "Windows"
    ]

    static let defaultMaxPromptCharacters = 900
    static let defaultMaxTerms = 96

    private static let storageKey = "openwhisper.vocabulary.learned.v1"

    private let defaults: UserDefaults
    private let maxPromptCharacters: Int
    private let maxTerms: Int

    init(
        defaults: UserDefaults = .standard,
        maxPromptCharacters: Int = VocabularyStore.defaultMaxPromptCharacters,
        maxTerms: Int = VocabularyStore.defaultMaxTerms
    ) {
        self.defaults = defaults
        self.maxPromptCharacters = max(64, maxPromptCharacters)
        self.maxTerms = max(1, maxTerms)
    }

    /// Learned terms, ordered by confidence and recency.
    var learnedTerms: [String] {
        loadLearnedTerms()
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                if $0.lastLearned != $1.lastLearned { return $0.lastLearned > $1.lastLearned }
                return $0.term.localizedStandardCompare($1.term) == .orderedAscending
            }
            .map(\.term)
    }

    /// Terms in the exact order used to build a prompt, before character limits.
    var candidateTerms: [String] {
        candidateTerms(from: loadLearnedTerms())
    }

    /// Native biasing shares correction rules and the prompt term budget.
    var nativeTerms: [String] {
        Array(correctionVocabulary().prefix(maxTerms).map(\.term))
    }

    private func candidateTerms(from records: [LearnedTerm]) -> [String] {
        var seen = Set<String>()
        let learned = records
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                if $0.lastLearned != $1.lastLearned { return $0.lastLearned > $1.lastLearned }
                return $0.term.localizedStandardCompare($1.term) == .orderedAscending
            }
            .map(\.term)

        return (learned + Self.bundledTerms).filter { term in
            let key = Self.comparisonKey(term)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    /// The bounded prompt used by Whisper's `initial_prompt` parameter.
    var initialPrompt: String? {
        makePrompt()
    }

    /// Builds a prompt with an optional caller-provided hint before local terms.
    /// The result stays within the configured character budget.
    func makePrompt(extra: String? = nil) -> String? {
        var pieces: [String] = []
        if let extra = normalizedExtra(extra) {
            pieces.append(extra)
        }

        for term in candidateTerms.prefix(maxTerms) {
            let candidate = pieces.isEmpty ? term : pieces.joined(separator: ", ") + ", " + term
            if candidate.count > maxPromptCharacters {
                break
            }
            pieces.append(term)
        }

        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: ", ")
    }

    /// Records a term supplied by a manual dictionary UI or setup code.
    @discardableResult
    func learn(term: String) -> Bool {
        let value = Self.normalizedTerm(term)
        guard Self.isLearnableTerm(value) else { return false }

        var records = loadLearnedTerms()
        let key = Self.comparisonKey(value)
        if let index = records.firstIndex(where: { Self.comparisonKey($0.term) == key }) {
            records[index].count += 1
            records[index].lastLearned = Date()
        } else {
            records.append(LearnedTerm(term: value))
        }
        save(records)
        return true
    }

    /// Adds comma- or newline-separated terms from the vocabulary editor.
    /// Empty entries and invalid values are ignored. The returned list uses
    /// the normalized spellings that were accepted by the store.
    @discardableResult
    func learnTerms(_ input: String) -> [String] {
        Self.parseTerms(input).filter { learn(term: $0) }
    }

    /// Splits user input into unique, normalized terms without changing the
    /// stored dictionary. The editor uses commas and newlines as separators.
    static func parseTerms(_ input: String) -> [String] {
        var seen = Set<String>()
        return input
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map(String.init)
            .compactMap { rawTerm in
                let normalized = normalizedTerm(rawTerm)
                let key = comparisonKey(normalized)
                guard !key.isEmpty, seen.insert(key).inserted else { return nil }
                return normalized
            }
    }

    /// Removes a learned term while leaving the bundled list unchanged.
    func forget(term: String) {
        let key = Self.comparisonKey(term)
        guard !key.isEmpty else { return }
        save(loadLearnedTerms().filter { Self.comparisonKey($0.term) != key })
    }

    /// Clears learned corrections. The static vocabulary remains available.
    func removeAllLearnedTerms() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    /// Applies local, deterministic corrections to a transcript.
    ///
    /// This is intentionally separate from the model prompt. A prompt is a
    /// probabilistic hint, while this pass can repair a close miss such as
    /// `poster SQL` -> `PostgreSQL` after Apple Speech has finished decoding.
    /// The pass only considers bundled terms with a technical spelling signal
    /// and terms that the user explicitly learned. Ordinary prose is left
    /// alone unless it exactly matches a canonical term.
    func correctTranscription(_ text: String) -> String {
        correctionSnapshot()(text)
    }

    /// Capture immutable spellings before moving expensive matching off the UI
    /// thread. Workers never access the defaults store or mutable UI state.
    func correctionSnapshot() -> @Sendable (String) -> String {
        let candidates = correctionVocabulary()
        return { Self.correctTranscription($0, candidates: candidates) }
    }

    private static func correctTranscription(_ text: String, candidates: [CorrectionVocabularyTerm]) -> String {
        guard !text.isEmpty else { return text }

        let tokens = correctionTokens(in: text)
        guard !tokens.isEmpty else { return text }

        guard !candidates.isEmpty else { return text }

        var replacements: [(range: Range<String.Index>, value: String)] = []
        var index = 0
        while index < tokens.count {
            var best: (end: Int, term: String, score: Double)?
            let maxLength = min(3, tokens.count - index)

            // Prefer the longest phrase. For equal lengths, choose the
            // closest spelling. This mirrors Handy's bounded n-gram matcher.
            for length in stride(from: maxLength, through: 1, by: -1) {
                let end = index + length
                guard phraseCanBeJoined(text, tokens: tokens, from: index, to: end) else { continue }
                let phrase = tokens[index..<end].map(\.text).joined(separator: " ")
                let phraseKey = Self.correctionKey(phrase)
                guard !phraseKey.isEmpty else { continue }

                for candidate in candidates {
                    let score = correctionScore(
                        phrase: phrase,
                        phraseKey: phraseKey,
                        candidate: candidate
                    )
                    guard let score else { continue }
                    // Handy uses 0.18 as its default fuzzy threshold. A
                    // multi-word phrase that targets a technical spelling
                    // carries stronger intent, so retain the existing
                    // phrase allowance up to the matcher’s 0.22 bound.
                    let threshold = candidate.hasTechnicalSpelling &&
                        phrase.contains(where: { $0.isWhitespace }) ? 0.22 : Self.correctionThreshold
                    guard score <= threshold else { continue }
                    if best == nil || score < best!.score ||
                        (score == best!.score && length > best!.end - index) {
                        best = (end, candidate.term, score)
                    }
                }
            }

            if let best {
                replacements.append((
                    range: tokens[index].range.lowerBound..<tokens[best.end - 1].range.upperBound,
                    value: best.term
                ))
                index = best.end
            } else {
                index += 1
            }
        }

        guard !replacements.isEmpty else { return text }
        var corrected = text
        for replacement in replacements.reversed() {
            corrected.replaceSubrange(replacement.range, with: replacement.value)
        }
        return corrected
    }

    private static func normalizedTerm(_ term: String) -> String {
        var value = term.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep developer punctuation inside a term (`Node.js`, `.NET`, `C++`),
        // but do not persist sentence punctuation from an edited text span.
        while let last = value.last, ".,!?;:)]}".contains(last) {
            value.removeLast()
        }
        while let first = value.first, "\"'([{".contains(first) {
            value.removeFirst()
        }
        return value
    }

    private static func comparisonKey(_ term: String) -> String {
        normalizedTerm(term).lowercased()
    }

    /// Handy's default custom-word threshold is 0.18. Keep the same
    /// conservative default so a close technical match is repaired without
    /// rewriting ordinary prose.
    private static let correctionThreshold = 0.18

    private struct CorrectionToken {
        let range: Range<String.Index>
        let text: String
    }

    private struct CorrectionVocabularyTerm: Sendable {
        let term: String
        let key: String
        let learned: Bool
        let hasTechnicalSpelling: Bool
    }

    // ponytail: known ambiguous acronyms require learning; add contextual
    // matching if users need them corrected automatically.
    private static let ambiguousBundledKeys: Set<String> = ["rest", "sam", "tam", "som", "til", "eta", "ram"]

    private func correctionVocabulary() -> [CorrectionVocabularyTerm] {
        let records = loadLearnedTerms()
        let learnedKeys = Set(records.map { Self.comparisonKey($0.term) })
        var seen = Set<String>()
        return candidateTerms(from: records).compactMap { term in
            let key = Self.correctionKey(term)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            let learned = learnedKeys.contains(Self.comparisonKey(term))
            guard learned || !Self.ambiguousBundledKeys.contains(key) else { return nil }
            let hasTechnicalSpelling = term.dropFirst().contains(where: { $0.isUppercase }) ||
                term.rangeOfCharacter(from: .decimalDigits) != nil ||
                term.contains(where: { ".#+_-/&".contains($0) })
            // Fuzzy replacement of ordinary prose creates surprising edits.
            // Learned terms are explicit user intent, so they are allowed.
            guard learned || hasTechnicalSpelling else { return nil }
            return CorrectionVocabularyTerm(
                term: term,
                key: key,
                learned: learned,
                hasTechnicalSpelling: hasTechnicalSpelling
            )
        }
    }

    private static let correctionTokenRegex = try! NSRegularExpression(
        pattern: "[\\p{L}\\p{N}][\\p{L}\\p{N}.+#&/_-]*"
    )

    private static func correctionTokens(in text: String) -> [CorrectionToken] {
        // Keep punctuation outside a token. This lets us preserve sentence
        // punctuation and prevents matching across commas or parentheses.
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        return correctionTokenRegex.matches(in: text, options: [], range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            var end = range.upperBound
            // A sentence period or closing punctuation belongs outside the
            // correction range. Developer punctuation such as `C++` remains.
            while end > range.lowerBound,
                  ".,!?;:)]}".contains(text[text.index(before: end)]) {
                let previous = text.index(before: end)
                end = previous
            }
            guard end > range.lowerBound else { return nil }
            return CorrectionToken(range: range.lowerBound..<end, text: String(text[range.lowerBound..<end]))
        }
    }

    private static func phraseCanBeJoined(_ text: String, tokens: [CorrectionToken], from start: Int, to end: Int) -> Bool {
        guard end - start > 1 else { return true }
        for index in start..<(end - 1) {
            let gap = tokens[index].range.upperBound..<tokens[index + 1].range.lowerBound
            guard text[gap].allSatisfy({ $0.isWhitespace }) else { return false }
        }
        return true
    }

    private static func correctionScore(
        phrase: String,
        phraseKey: String,
        candidate: CorrectionVocabularyTerm
    ) -> Double? {
        if phraseKey == candidate.key {
            // Do not title-case ordinary prose (`task` should remain
            // `task`). Canonicalize acronyms, developer punctuation, internal
            // capitals, and terms that the user explicitly learned.
            //
            // Punctuation is removed from comparison keys so spoken and
            // written forms can meet (`Node.js` / `nodejs`). Very short
            // punctuated terms would otherwise collapse onto ordinary words:
            // `C++` and `C#` both have the key `c`, while `.NET` has `net`.
            // Keep those bundled aliases gated unless the input includes the
            // punctuation or the user explicitly pinned the term.
            let hasPunctuation = candidate.term.contains {
                !$0.isLetter && !$0.isNumber && !$0.isWhitespace
            }
            let inputHasPunctuation = phrase.contains {
                !$0.isLetter && !$0.isNumber && !$0.isWhitespace
            }
            if hasPunctuation && !inputHasPunctuation && !candidate.learned && candidate.key.count < 4 {
                return nil
            }
            let uppercaseCount = candidate.term.filter({ $0.isUppercase }).count
            let hasCanonicalSignal = candidate.learned ||
                uppercaseCount >= 2 ||
                candidate.term.contains(where: { ".#+_-/&".contains($0) }) ||
                candidate.term.allSatisfy({ !$0.isLetter || $0.isUppercase })
            return hasCanonicalSignal ? 0 : nil
        }

        let lengthDifference = abs(phraseKey.count - candidate.key.count)
        let maximumLength = max(phraseKey.count, candidate.key.count)
        guard lengthDifference <= max(2, Int(Double(maximumLength) * 0.25)) else { return nil }

        let distance = Self.levenshteinDistance(phraseKey, candidate.key)
        var score = Double(distance) / Double(maximumLength)

        // Soundex is useful for terms such as `Nyzi` -> `NYSE`, but only for
        // a single ASCII word. Multi-word phonetic matching causes false
        // positives in ordinary sentences.
        let isSingleWord = !phrase.contains(where: { $0.isWhitespace }) &&
            !candidate.term.contains(where: { $0.isWhitespace })
        var usedPhoneticBoost = false
        if isSingleWord,
           phraseKey.count >= 4,
           candidate.key.count >= 4,
           phraseKey.count == candidate.key.count,
           candidate.term.filter({ $0.isUppercase }).count >= 2,
           let lhs = Self.soundex(phraseKey),
           let rhs = Self.soundex(candidate.key),
           lhs == rhs,
           hasInteriorSpellingAnchor(phraseKey, candidate.key) {
            score *= 0.3
            usedPhoneticBoost = true
        }

        // A single ordinary word at exactly 20% edit distance is ambiguous
        // (`Jason` and `JSON` are a useful example). Multi-word phrases have
        // stronger intent because the phrase boundary is part of the match.
        if !usedPhoneticBoost,
           isSingleWord,
           score >= 0.20 {
            return nil
        }
        // A one-word canonical term matched against several transcript words
        // must be very close. This avoids swallowing a short function word,
        // for example `to AcmeDB` -> `AcmeDB`.
        if !isSingleWord, score > 0.22 {
            return nil
        }

        return score
    }

    /// Soundex intentionally ignores most vowel and consonant placement. Keep
    /// one same-position interior character as an inexpensive guard so a
    /// common word such as `nice` does not become `NYSE`, while variants such
    /// as `Nyzi` and `Nisy` can still reach the acronym.
    private static func hasInteriorSpellingAnchor(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs)
        let right = Array(rhs)
        guard left.count == right.count, left.count > 2 else { return false }
        return zip(left.dropFirst().dropLast(), right.dropFirst().dropLast())
            .contains { $0 == $1 }
    }

    private static func correctionKey(_ value: String) -> String {
        value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0).lowercased() }
            .joined()
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)
            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                current.append(min(substitution, insertion, deletion))
            }
            previous = current
        }
        return previous[right.count]
    }

    private static func soundex(_ value: String) -> String? {
        let scalars = value.uppercased().unicodeScalars
        guard scalars.allSatisfy({ CharacterSet.letters.contains($0) }),
              let first = scalars.first else { return nil }

        func code(_ scalar: Unicode.Scalar) -> Character? {
            switch scalar {
            case "B", "F", "P", "V": return "1"
            case "C", "G", "J", "K", "Q", "S", "X", "Z": return "2"
            case "D", "T": return "3"
            case "L": return "4"
            case "M", "N": return "5"
            case "R": return "6"
            default: return nil
            }
        }

        let firstCharacter = Character(String(first))
        var result = String(firstCharacter)
        var previousCode: Character?
        for scalar in scalars.dropFirst() {
            if let currentCode = code(scalar) {
                if currentCode != previousCode {
                    result.append(currentCode)
                }
                previousCode = currentCode
            } else {
                previousCode = nil
            }
            if result.count == 4 { break }
        }
        while result.count < 4 { result.append("0") }
        return result
    }

    private static func isLearnableTerm(_ term: String) -> Bool {
        guard term.count >= 2, term.count <= 64,
              term.rangeOfCharacter(from: .letters) != nil,
              !term.contains(where: { $0.isNewline }),
              term.split(whereSeparator: { $0.isWhitespace }).count <= 4 else {
            return false
        }

        // Manual entries are explicit user intent. Lowercase names and ordinary
        // words are valid here, even though fuzzy automatic correction remains
        // restricted to learned terms and technical spellings.
        return true
    }

    private func normalizedExtra(_ extra: String?) -> String? {
        guard let extra else { return nil }
        let value = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return String(value.prefix(maxPromptCharacters))
    }

    // MARK: - Persistence

    private func loadLearnedTerms() -> [LearnedTerm] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let records = try? JSONDecoder().decode([LearnedTerm].self, from: data) else {
            return []
        }
        return records.filter { Self.isLearnableTerm($0.term) && $0.count > 0 }
    }

    private func save(_ records: [LearnedTerm]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
