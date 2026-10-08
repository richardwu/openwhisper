import SwiftUI

/// Editor for user-pinned spellings. The bundled dictionary remains active
/// for every backend, while this screen stores names that are specific to the
/// user's work. Layout mirrors `HistoryView`: a compact toolbar strip above a
/// plain list.
struct VocabularyTabView: View {
    let appState: AppState

    @State private var input = ""
    @State private var searchText = ""
    @State private var learnedTerms: [String] = []
    @State private var showDeleteAllConfirmation = false

    private var filteredTerms: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return learnedTerms }
        return learnedTerms.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var countLabel: String {
        let total = learnedTerms.count == 1 ? "1 term" : "\(learnedTerms.count) terms"
        return filteredTerms.count == learnedTerms.count ? total : "\(filteredTerms.count) of \(total)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Add terms, e.g. AcmeDB, PostgreSQL, NYSE", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("vocabulary.input")
                    .onSubmit(addTerms)
                Button("Add", action: addTerms)
                    .buttonStyle(.borderedProminent)
                    .disabled(VocabularyStore.parseTerms(input).isEmpty)
                    .accessibilityIdentifier("vocabulary.add")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if learnedTerms.isEmpty {
                ContentUnavailableView(
                    "No Pinned Terms",
                    systemImage: "text.book.closed",
                    description: Text("Add names and jargon so transcriptions spell them correctly. Terms stay on this Mac.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("vocabulary.empty")
            } else {
                HStack(spacing: 8) {
                    Text(countLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("vocabulary.count")
                    Spacer()
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                        .accessibilityIdentifier("vocabulary.search")
                    Button("Delete All", role: .destructive) {
                        showDeleteAllConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)
                    .accessibilityIdentifier("vocabulary.deleteAll")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if filteredTerms.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("vocabulary.noMatches")
                } else {
                    List(filteredTerms, id: \.self) { term in
                        HStack {
                            Text(term)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("vocabulary.term.\(term)")
                            Spacer()
                            Button {
                                remove(term)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Delete")
                            .accessibilityLabel("Delete \(term)")
                            .accessibilityIdentifier("vocabulary.remove.\(term)")
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button("Delete", role: .destructive) { remove(term) }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: reloadTerms)
        .alert("Delete All Pinned Terms?", isPresented: $showDeleteAllConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All", role: .destructive) {
                appState.transcriptionService.forgetAllVocabularyTerms()
                searchText = ""
                reloadTerms()
            }
        } message: {
            Text("This will permanently delete all \(learnedTerms.count) pinned terms. The built-in vocabulary is not affected.")
        }
    }

    private func addTerms() {
        let added = appState.transcriptionService.learnVocabularyTerms(input)
        guard !added.isEmpty else { return }
        input = ""
        reloadTerms()
    }

    private func remove(_ term: String) {
        appState.transcriptionService.forgetVocabularyTerm(term)
        reloadTerms()
    }

    private func reloadTerms() {
        learnedTerms = appState.transcriptionService.learnedVocabularyTerms
    }
}
