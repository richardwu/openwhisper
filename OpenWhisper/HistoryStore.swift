import Foundation

struct TranscriptionEntry: Identifiable, Codable {
    let id: UUID
    let text: String
    let date: Date

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.date = Date()
    }
}

@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [TranscriptionEntry] = []

    private static let storageKey = "transcriptionHistory"

    init() {
        load()
    }

    func add(text: String) {
        let entry = TranscriptionEntry(text: text)
        entries.insert(entry, at: 0)
        save()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([TranscriptionEntry].self, from: data)
        else { return }
        entries = decoded
    }
}
