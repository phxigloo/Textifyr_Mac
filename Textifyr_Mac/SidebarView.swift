import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

// Pairs a document with the context snippet that explains why it matched a search.
private struct FilteredDoc: Identifiable {
    let document: TextifyrDocument
    let snippet: String?       // nil when matched by title (title is already visible)
    var id: UUID { document.id }
}

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TextifyrDocument.sortOrder) private var documents: [TextifyrDocument]

    @State private var searchText = ""
    @State private var selectedID: UUID?
    @State private var showDeleteConfirmation = false
    @State private var documentToDelete: TextifyrDocument?

    private var filteredDocs: [FilteredDoc] {
        guard !searchText.isEmpty else {
            return documents.map { FilteredDoc(document: $0, snippet: nil) }
        }
        return documents.compactMap { doc in
            if doc.title.localizedCaseInsensitiveContains(searchText) {
                return FilteredDoc(document: doc, snippet: nil)
            }
            let sources = doc.mergedSourceText
            if sources.localizedCaseInsensitiveContains(searchText) {
                return FilteredDoc(document: doc,
                                   snippet: sidebarSnippet(in: sources, term: searchText, label: "Sources"))
            }
            if let rtf = doc.outputRTF,
               let plain = NSAttributedString(rtf: rtf, documentAttributes: nil)?.string,
               plain.localizedCaseInsensitiveContains(searchText) {
                return FilteredDoc(document: doc,
                                   snippet: sidebarSnippet(in: plain, term: searchText, label: "Output"))
            }
            return nil
        }
    }

    private var selectedDocument: TextifyrDocument? {
        guard let id = selectedID else { return nil }
        return documents.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(filteredDocs, selection: $selectedID) { item in
                SidebarRow(document: item.document, snippet: item.snippet)
                    .tag(item.document.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            documentToDelete = item.document
                            showDeleteConfirmation = true
                        }
                    }
            }
            .searchable(text: $searchText, placement: .sidebar)
            .listStyle(.sidebar)
            .navigationTitle("")

            Divider()

            // + / - footer
            HStack(spacing: 12) {
                Button {
                    createDocument()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("New Document (⌘N)")

                Button {
                    if let doc = selectedDocument {
                        documentToDelete = doc
                        showDeleteConfirmation = true
                    }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(selectedDocument == nil)
                .help("Delete selected document")

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(.bar)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newDocument)) { _ in
            createDocument()
        }
        .onChange(of: selectedID) { _, id in
            appState.selectedDocument = documents.first { $0.id == id }
        }
        .onChange(of: appState.selectedDocument?.id) { _, id in
            if selectedID != id { selectedID = id }
        }
        .confirmationDialog("Delete Document", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let doc = documentToDelete { delete(doc) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let title = documentToDelete?.title ?? "this document"
            Text("Delete \"\(title)\"? This cannot be undone.")
        }
    }

    private func createDocument() {
        let doc = TextifyrDocument(title: "Untitled")
        doc.sortOrder = documents.count
        modelContext.insert(doc)
        try? modelContext.save()
        appState.selectedDocument = doc
    }

    private func delete(_ doc: TextifyrDocument) {
        if appState.selectedDocument?.id == doc.id {
            appState.selectedDocument = nil
        }
        selectedID = nil
        modelContext.delete(doc)
        try? modelContext.save()
    }
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let document: TextifyrDocument
    let snippet: String?
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkStage.sortOrder) private var stages: [WorkStage]

    var body: some View {
        HStack(alignment: snippet != nil ? .top : .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(.body)
                    .lineLimit(1)
                if let snippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            // Stage badge: visual is drawn separately so Menu chrome doesn't affect colors
            if let stage = document.stage {
                StageBadgeView(stage: stage)
                    .overlay(
                        Menu {
                            ForEach(stages) { s in
                                Button {
                                    document.stage = s
                                    try? modelContext.save()
                                } label: {
                                    HStack {
                                        Text(s.name)
                                        if document.stage?.id == s.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("Clear Stage", role: .destructive) {
                                document.stage = nil
                                try? modelContext.save()
                            }
                        } label: {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                    )
                    .fixedSize()
            } else {
                Menu {
                    ForEach(stages) { s in
                        Button {
                            document.stage = s
                            try? modelContext.save()
                        } label: { Text(s.name) }
                    }
                } label: {
                    Image(systemName: "tag")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Search snippet helper

/// Extracts a short context fragment around the first occurrence of `term` in `text`.
/// Returns a labelled string like "Sources: …matched content here…"
private func sidebarSnippet(in text: String, term: String, label: String, radius: Int = 55) -> String {
    let ns = text as NSString
    let matchRange = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
    guard matchRange.location != NSNotFound else { return "\(label): …" }

    let start = max(0, matchRange.location - radius)
    let end   = min(ns.length, matchRange.location + matchRange.length + radius)
    var fragment = ns.substring(with: NSRange(location: start, length: end - start))

    // Collapse runs of whitespace/newlines so the snippet reads as a single line
    fragment = fragment
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")

    let pre  = start > 0         ? "…" : ""
    let post = end < ns.length   ? "…" : ""
    return "\(label): \(pre)\(fragment)\(post)"
}

#Preview("Sidebar with documents") {
    let c = makePreviewContainer()
    let appState = previewAppState(selectedIn: c)
    return SidebarView()
        .modelContainer(c)
        .environmentObject(appState)
        .frame(width: 260, height: 500)
}
