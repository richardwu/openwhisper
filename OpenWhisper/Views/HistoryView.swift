import SwiftUI

struct HistoryView: View {
    let historyStore: HistoryStore
    @State private var entryToDelete: TranscriptionEntry?
    @State private var showDeleteAllConfirmation = false
    @State private var copiedEntryID: UUID?

    var body: some View {
        if historyStore.entries.isEmpty {
            ContentUnavailableView(
                "No Transcriptions Yet",
                systemImage: "clock",
                description: Text("Your transcription history will appear here.")
            )
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text(historyStore.entries.count == 1
                         ? "1 transcription"
                         : "\(historyStore.entries.count) transcriptions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete All", role: .destructive) {
                        showDeleteAllConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                List {
                    ForEach(historyStore.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.text)
                                .font(.body)
                                .lineLimit(4)
                                .textSelection(.enabled)

                            HStack {
                                Text(entry.date, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Button {
                                    copyEntry(entry)
                                } label: {
                                    if copiedEntryID == entry.id {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    } else {
                                        Image(systemName: "doc.on.doc")
                                            .font(.caption)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .help("Copy to clipboard")

                                Button {
                                    entryToDelete = entry
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .help("Delete")
                            }
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button("Copy") {
                                copyEntry(entry)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                entryToDelete = entry
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .alert("Delete All Transcriptions?", isPresented: $showDeleteAllConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete All", role: .destructive) {
                    historyStore.clearAll()
                }
            } message: {
                Text("This will permanently delete all \(historyStore.entries.count) transcriptions.")
            }
            .alert("Delete Transcription?",
                   isPresented: Binding(
                    get: { entryToDelete != nil },
                    set: { if !$0 { entryToDelete = nil } }
                   )
            ) {
                Button("Cancel", role: .cancel) {
                    entryToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let entry = entryToDelete {
                        historyStore.delete(id: entry.id)
                        entryToDelete = nil
                    }
                }
            } message: {
                if let entry = entryToDelete {
                    Text("Delete \"\(String(entry.text.prefix(60)))\(entry.text.count > 60 ? "..." : "")\"?")
                }
            }
        }
    }

    private func copyEntry(_ entry: TranscriptionEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copiedEntryID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedEntryID == entry.id {
                copiedEntryID = nil
            }
        }
    }
}
