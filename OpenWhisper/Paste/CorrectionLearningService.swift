import AppKit
import ApplicationServices

/// A focused text target that OpenWhisper can observe for one paste session.
///
/// The native target contains the Accessibility element. Tests use the stable
/// identifier and do not need to create an Accessibility element.
final class CorrectionTextTarget {
    let identifier: String
    fileprivate let nativeElement: AXUIElement?

    init(identifier: String, nativeElement: AXUIElement? = nil) {
        self.identifier = identifier
        self.nativeElement = nativeElement
    }
}

struct CorrectionTextSnapshot {
    /// Text is bounded by CorrectionLearningService.maxObservedCharacters.
    let text: String
    /// UTF-16 offset of `text` in the target's value.
    let offset: Int
    /// The target's selected range in its complete value, when exposed.
    let selectedRange: NSRange?

    init(text: String, offset: Int = 0, selectedRange: NSRange? = nil) {
        self.text = text
        self.offset = offset
        self.selectedRange = selectedRange
    }
}

/// Reads one focused Accessibility text element at a time.
///
/// Implementations must not install keyboard monitors. The live implementation
/// only reads the focused element immediately before a paste and for a short
/// post-paste window.
@MainActor
protocol CorrectionAccessibilityReader: AnyObject {
    func focusedTextSnapshot() -> (target: CorrectionTextTarget, snapshot: CorrectionTextSnapshot)?
    func textSnapshot(for target: CorrectionTextTarget, around range: NSRange) -> CorrectionTextSnapshot?
    func isStillFocused(_ target: CorrectionTextTarget) -> Bool
}

/// Learns a small number of high-confidence spelling corrections from text
/// inserted by OpenWhisper. It never observes key-down or key-up events.
@MainActor
final class CorrectionLearningService {
    struct Entry: Codable, Equatable, Identifiable {
        let id: UUID
        let original: String
        let replacement: String
        var count: Int
        var lastSeen: Date

        init(id: UUID = UUID(), original: String, replacement: String, count: Int = 1, lastSeen: Date = Date()) {
            self.id = id
            self.original = original
            self.replacement = replacement
            self.count = count
            self.lastSeen = lastSeen
        }
    }

    /// A small value keeps both Accessibility reads and the persisted store bounded.
    static let maxObservedCharacters = 4096
    private static let maxEntries = 128
    private static let maxCorrectionCharacters = 80
    private static let maxCorrectionWords = 4
    private static let defaultsKey = "correction-learning.entries.v1"

    private struct Session {
        let target: CorrectionTextTarget
        let original: String
        var insertionRange: NSRange
        let expectedText: String
        var lastSnapshot: CorrectionTextSnapshot
        var pasteObserved = false
        var pendingEdit: TextEdit?
        var sawUnrelatedEdit = false
        let startedAt: Date
    }

    private struct TextEdit {
        let oldRange: NSRange
        let newRange: NSRange
        let oldText: String
        let newText: String
    }

    private let reader: CorrectionAccessibilityReader
    private let defaults: UserDefaults
    private let recordCorrectionHandler: ((String, String) -> Bool)?
    private let learnedTermsProvider: (() -> [String])?
    private var observationTask: Task<Void, Never>?
    private var session: Session?

    private(set) var entries: [Entry]

    /// Learned replacement spellings, ordered by confidence and recency.
    /// The caller can add these terms to the transcription prompt.
    var learnedTerms: [String] {
        if let learnedTermsProvider {
            return learnedTermsProvider()
        }
        return entries
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.lastSeen > rhs.lastSeen
            }
            .map(\.replacement)
    }

    init(reader: CorrectionAccessibilityReader? = nil,
         defaults: UserDefaults = .standard,
         recordCorrection: ((String, String) -> Bool)? = nil,
         learnedTerms: (() -> [String])? = nil) {
        self.reader = reader ?? SystemCorrectionAccessibilityReader()
        self.defaults = defaults
        self.recordCorrectionHandler = recordCorrection
        self.learnedTermsProvider = learnedTerms
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
    }

    deinit {
        observationTask?.cancel()
    }

    /// Begin observing the focused text element before the paste occurs.
    ///
    /// If the application does not expose a selected range, the service skips
    /// learning. This avoids guessing which text belongs to OpenWhisper.
    func beginInsertion(_ text: String) {
        finishObservation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let focused = reader.focusedTextSnapshot(),
              let selectedRange = focused.snapshot.selectedRange,
              selectedRange.location >= focused.snapshot.offset,
              selectedRange.location + selectedRange.length <= focused.snapshot.offset + focused.snapshot.text.utf16.count else {
            return
        }

        let localSelection = NSRange(
            location: selectedRange.location - focused.snapshot.offset,
            length: selectedRange.length
        )
        let baselineNSString = focused.snapshot.text as NSString
        let replacement = text as NSString
        let expectedNSString = baselineNSString.replacingCharacters(in: localSelection, with: text) as NSString
        let insertionStart = selectedRange.location
        let insertionRange = NSRange(location: insertionStart, length: replacement.length)
        let expectedText = expectedNSString as String

        session = Session(
            target: focused.target,
            original: text,
            insertionRange: insertionRange,
            expectedText: expectedText,
            lastSnapshot: focused.snapshot,
            startedAt: Date()
        )

        // Observe only while the user can reasonably correct the just-inserted text.
        observationTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                self.observeCurrentText()
                if self.session == nil { return }
            }
            self.finishObservation()
        }
    }

    /// Returns entries for prompt generation without exposing the source text.
    func correctionsPrompt(maxCharacters: Int = 800) -> String {
        var result = ""
        for term in learnedTerms {
            let separator = result.isEmpty ? "" : ", "
            guard result.utf16.count + separator.utf16.count + term.utf16.count <= maxCharacters else { break }
            result += separator + term
        }
        return result
    }

    /// Used by tests and by any future event-driven Accessibility adapter.
    func observeCurrentText() {
        guard var current = session else { return }
        guard Date().timeIntervalSince(current.startedAt) <= 8 else {
            finishObservation()
            return
        }
        guard reader.isStillFocused(current.target),
              let snapshot = reader.textSnapshot(for: current.target, around: current.insertionRange) else {
            finishObservation()
            return
        }

        if !current.pasteObserved {
            // Wait until the target reflects our paste. A user may type before
            // the target processes Cmd-V; that case is intentionally ignored.
            let expectedOffset = current.insertionRange.location - snapshot.offset
            // Match the text OpenWhisper inserted at the recorded range. The
            // surrounding field may exceed the bounded snapshot window.
            if snapshot.text == current.expectedText || containsExpectedText(snapshot, expectedOffset: expectedOffset, expected: current.original) {
                current.pasteObserved = true
                current.lastSnapshot = snapshot
                session = current
            }
            return
        }

        guard snapshot.text != current.lastSnapshot.text || snapshot.offset != current.lastSnapshot.offset else {
            return
        }
        guard let rawEdit = singleEdit(from: current.lastSnapshot, to: snapshot) else {
            current.sawUnrelatedEdit = true
            current.lastSnapshot = snapshot
            session = current
            return
        }
        // Check the minimal diff before expanding it. An edit immediately
        // after the insertion can expand backward into the inserted word;
        // that must remain unrelated text.
        let oldRange = current.insertionRange
        guard rangesOverlap(rawEdit.oldRange, oldRange) || rangesOverlap(rawEdit.newRange, oldRange) else {
            current.sawUnrelatedEdit = true
            current.lastSnapshot = snapshot
            session = current
            return
        }
        let edit = expandToWordBoundaries(
            rawEdit,
            oldSnapshot: current.lastSnapshot,
            newSnapshot: snapshot
        )

        let touchesInsertion = rangesOverlap(edit.oldRange, oldRange)
        let touchesNewInsertion = rangesOverlap(edit.newRange, oldRange)

        if touchesInsertion || touchesNewInsertion {
            if current.pendingEdit != nil {
                // More than one correction is ambiguous. Keep the paste safe
                // and do not learn a phrase that may include unrelated editing.
                current.sawUnrelatedEdit = true
            } else {
                current.pendingEdit = edit
            }
            var updated = current
            let delta = edit.newRange.length - edit.oldRange.length
            if edit.oldRange.location < oldRange.location {
                updated.insertionRange.location += delta
            } else {
                updated.insertionRange.length = max(0, updated.insertionRange.length + delta)
            }
            updated.lastSnapshot = snapshot
            session = updated
        } else {
            current.sawUnrelatedEdit = true
            current.lastSnapshot = snapshot
            session = current
        }
    }

    /// Ends an observation and stores a correction only when one bounded edit is clear.
    func finishObservation() {
        observationTask?.cancel()
        observationTask = nil
        guard let current = session else { return }
        session = nil
        guard current.pasteObserved,
              !current.sawUnrelatedEdit,
              let edit = current.pendingEdit,
              isLearnable(original: edit.oldText, replacement: edit.newText) else {
            return
        }
        save(original: edit.oldText, replacement: edit.newText)
    }

    // MARK: - Persistence and validation

    private func save(original: String, replacement: String) {
        let normalizedOriginal = normalize(original)
        let normalizedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOriginal.isEmpty, !normalizedReplacement.isEmpty else { return }

        // The live application supplies TranscriptionService here, keeping
        // VocabularyStore as the single persisted source of learned terms.
        // The local fallback remains useful for isolated unit tests.
        if let recordCorrectionHandler {
            _ = recordCorrectionHandler(original, replacement)
            return
        }

        if let index = entries.firstIndex(where: {
            normalize($0.original) == normalizedOriginal && $0.replacement == normalizedReplacement
        }) {
            entries[index].count += 1
            entries[index].lastSeen = Date()
        } else {
            entries.append(Entry(original: original, replacement: normalizedReplacement))
        }
        if entries.count > Self.maxEntries {
            entries.sort { $0.lastSeen > $1.lastSeen }
            entries.removeLast(entries.count - Self.maxEntries)
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private func isLearnable(original: String, replacement: String) -> Bool {
        let old = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !new.isEmpty, old != new,
              old.utf16.count <= Self.maxCorrectionCharacters,
              new.utf16.count <= Self.maxCorrectionCharacters,
              wordCount(old) <= Self.maxCorrectionWords,
              wordCount(new) <= Self.maxCorrectionWords else { return false }

        // Do not learn a changed number, URL, or multiline rewrite.
        guard !old.contains("\n"), !new.contains("\n"),
              digits(in: old) == digits(in: new),
              !new.contains("http://"), !new.contains("https://") else { return false }
        return true
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func wordCount(_ value: String) -> Int {
        value.split { $0 == " " || $0 == "\t" }.count
    }

    private func digits(in value: String) -> [Character] {
        value.filter(\.isNumber)
    }

    private func containsExpectedText(_ snapshot: CorrectionTextSnapshot, expectedOffset: Int, expected: String) -> Bool {
        guard expectedOffset >= 0 else { return false }
        let ns = snapshot.text as NSString
        guard expectedOffset + (expected as NSString).length <= ns.length else { return false }
        return ns.substring(with: NSRange(location: expectedOffset, length: (expected as NSString).length)) == expected
    }

    private func singleEdit(from old: CorrectionTextSnapshot, to new: CorrectionTextSnapshot) -> TextEdit? {
        // The live reader uses a fixed-size window around the insertion. Refuse
        // comparisons when the window moved, because the changed text is unknown.
        guard old.offset == new.offset else { return nil }
        let oldString = old.text as NSString
        let newString = new.text as NSString
        var prefix = 0
        while prefix < oldString.length && prefix < newString.length,
              oldString.character(at: prefix) == newString.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldString.length - prefix && suffix < newString.length - prefix,
              oldString.character(at: oldString.length - suffix - 1) == newString.character(at: newString.length - suffix - 1) {
            suffix += 1
        }
        let oldRange = NSRange(location: old.offset + prefix, length: oldString.length - prefix - suffix)
        let newRange = NSRange(location: new.offset + prefix, length: newString.length - prefix - suffix)
        return TextEdit(
            oldRange: oldRange,
            newRange: newRange,
            oldText: oldString.substring(with: NSRange(location: prefix, length: oldRange.length)),
            newText: newString.substring(with: NSRange(location: prefix, length: newRange.length))
        )
    }

    /// A case or word-joining correction often shares a suffix with the
    /// original term. Expand the raw character diff to complete whitespace
    /// delimited terms before persisting it.
    private func expandToWordBoundaries(
        _ edit: TextEdit,
        oldSnapshot: CorrectionTextSnapshot,
        newSnapshot: CorrectionTextSnapshot
    ) -> TextEdit {
        let oldString = oldSnapshot.text as NSString
        let newString = newSnapshot.text as NSString
        var oldStart = max(0, edit.oldRange.location - oldSnapshot.offset)
        var oldEnd = min(oldString.length, oldStart + edit.oldRange.length)
        var newStart = max(0, edit.newRange.location - newSnapshot.offset)
        var newEnd = min(newString.length, newStart + edit.newRange.length)

        while oldStart > 0 && !isWhitespace(oldString.character(at: oldStart - 1)) {
            oldStart -= 1
        }
        while oldEnd < oldString.length && !isWhitespace(oldString.character(at: oldEnd)) {
            oldEnd += 1
        }
        while newStart > 0 && !isWhitespace(newString.character(at: newStart - 1)) {
            newStart -= 1
        }
        while newEnd < newString.length && !isWhitespace(newString.character(at: newEnd)) {
            newEnd += 1
        }

        return TextEdit(
            oldRange: NSRange(location: oldSnapshot.offset + oldStart, length: oldEnd - oldStart),
            newRange: NSRange(location: newSnapshot.offset + newStart, length: newEnd - newStart),
            oldText: oldString.substring(with: NSRange(location: oldStart, length: oldEnd - oldStart)),
            newText: newString.substring(with: NSRange(location: newStart, length: newEnd - newStart))
        )
    }

    private func isWhitespace(_ value: unichar) -> Bool {
        Character(UnicodeScalar(value)!).isWhitespace
    }

    private func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        let lhsEnd = lhs.location + lhs.length
        let rhsEnd = rhs.location + rhs.length
        if lhs.length == 0 {
            return lhs.location >= rhs.location && lhs.location < rhsEnd
        }
        return lhs.location < rhsEnd && lhsEnd > rhs.location
    }
}

/// Accessibility implementation used by the live application.
@MainActor
final class SystemCorrectionAccessibilityReader: CorrectionAccessibilityReader {
    private let maxCharacters = CorrectionLearningService.maxObservedCharacters

    func focusedTextSnapshot() -> (target: CorrectionTextTarget, snapshot: CorrectionTextSnapshot)? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        guard let app = copyElement(system, attribute: kAXFocusedApplicationAttribute as CFString),
              let element = copyElement(app, attribute: kAXFocusedUIElementAttribute as CFString),
              !isSecure(element),
              let value = copyString(element, attribute: kAXValueAttribute as CFString) else { return nil }
        let selection = copyRange(element, attribute: kAXSelectedTextRangeAttribute as CFString)
        let target = CorrectionTextTarget(identifier: "focused", nativeElement: element)
        return (target, makeSnapshot(value: value, selection: selection, around: selection))
    }

    func textSnapshot(for target: CorrectionTextTarget, around range: NSRange) -> CorrectionTextSnapshot? {
        guard let element = target.nativeElement,
              !isSecure(element),
              let value = copyString(element, attribute: kAXValueAttribute as CFString) else { return nil }
        let selection = copyRange(element, attribute: kAXSelectedTextRangeAttribute as CFString)
        return makeSnapshot(value: value, selection: selection, around: range)
    }

    func isStillFocused(_ target: CorrectionTextTarget) -> Bool {
        guard let targetElement = target.nativeElement else { return false }
        let system = AXUIElementCreateSystemWide()
        guard let app = copyElement(system, attribute: kAXFocusedApplicationAttribute as CFString),
              let focused = copyElement(app, attribute: kAXFocusedUIElementAttribute as CFString) else { return false }
        return CFEqual(targetElement, focused)
    }

    private func makeSnapshot(value: String, selection: NSRange?, around range: NSRange?) -> CorrectionTextSnapshot {
        let ns = value as NSString
        guard ns.length > maxCharacters else {
            return CorrectionTextSnapshot(text: value, offset: 0, selectedRange: selection)
        }
        let center = min(max(0, range?.location ?? selection?.location ?? ns.length), ns.length)
        let start = min(max(0, center - maxCharacters / 2), max(0, ns.length - maxCharacters))
        let window = ns.substring(with: NSRange(location: start, length: min(maxCharacters, ns.length - start)))
        return CorrectionTextSnapshot(text: window, offset: start, selectedRange: selection)
    }

    private func copyElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func copyString(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { return nil }
        return value as? String
    }

    private func copyRange(_ element: AXUIElement, attribute: CFString) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String else { return false }
        return subrole == kAXSecureTextFieldSubrole as String
    }
}
