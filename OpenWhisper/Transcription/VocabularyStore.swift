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
        var seen = Set<String>()
        let learned = loadLearnedTerms()
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

    /// Records one explicit spelling correction. The API accepts a whole
    /// replacement so an observer can pass the text before and after editing.
    /// It stores only a changed, term-like token and never stores the sentence.
    @discardableResult
    func recordCorrection(from original: String, to corrected: String) -> Bool {
        let before = Self.tokens(in: original)
        let after = Self.tokens(in: corrected)
        guard !before.isEmpty, !after.isEmpty, before != after else { return false }

        let candidates = correctionCandidates(before: before, after: after)
        var learned = false
        for candidate in candidates where Self.isLearnableTerm(candidate) {
            learned = learn(term: candidate) || learned
        }
        return learned
    }

    /// Records a term supplied by a correction observer or a manual UI.
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

    // MARK: - Correction extraction

    private func correctionCandidates(before: [String], after: [String]) -> [String] {
        // Compare only the changed span. This supports a common correction
        // such as "use open whisper" -> "use OpenWhisper" without retaining
        // the surrounding sentence.
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] {
            prefix += 1
        }

        var beforeEnd = before.count
        var afterEnd = after.count
        while beforeEnd > prefix, afterEnd > prefix,
              before[beforeEnd - 1] == after[afterEnd - 1] {
            beforeEnd -= 1
            afterEnd -= 1
        }

        let changedBefore = Array(before[prefix..<beforeEnd])
        let changedAfter = Array(after[prefix..<afterEnd])
        guard !changedBefore.isEmpty, !changedAfter.isEmpty else { return [] }

        // Accept word joining only when the replacement has exactly the same
        // letters as the old span. This rejects arbitrary rewrites.
        if changedAfter.count == 1,
           changedBefore.joined().lowercased() == Self.normalizedTerm(changedAfter[0]).lowercased() {
            return changedAfter
        }

        guard changedBefore.count == changedAfter.count else { return [] }
        return zip(changedBefore, changedAfter).compactMap { old, new in
            old == new ? nil : new
        }
    }

    private static func tokens(in text: String) -> [String] {
        text.split { character in
            character.isWhitespace || character.isPunctuation && character != "." && character != "+" && character != "#" && character != "-" && character != "_"
        }.map(String.init)
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

    private static func isLearnableTerm(_ term: String) -> Bool {
        guard term.count >= 2, term.count <= 64,
              term.rangeOfCharacter(from: .letters) != nil,
              term.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }

        // A changed capitalization, acronym, digit, or developer punctuation
        // is useful evidence. This avoids learning ordinary prose corrections
        // such as "teh" -> "the".
        let hasUppercase = term.rangeOfCharacter(from: .uppercaseLetters) != nil
        let hasDigit = term.rangeOfCharacter(from: .decimalDigits) != nil
        let hasDeveloperPunctuation = term.contains(where: { ".#+_-".contains($0) })
        return hasUppercase || hasDigit || hasDeveloperPunctuation
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
