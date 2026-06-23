import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
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
    @State private var isDropTargeted = false

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
            // Manual search field. (A `.searchable(.sidebar)` field renders in the
            // title-bar region, which the Phase 22 mode bar now occupies — so it was
            // being clipped. A plain field below the mode bar avoids that.)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            List(filteredDocs, selection: $selectedID) { item in
                SidebarRow(document: item.document, snippet: item.snippet)
                    .tag(item.document.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            documentToDelete = item.document
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            documentToDelete = item.document
                            showDeleteConfirmation = true
                        }
                    }
            }
            .listStyle(.sidebar)
            .navigationTitle("")
            // Drop files here to create a new document from them.
            .dropDestination(for: URL.self) { urls, _ in
                FileDropImporter.handleDrop(urls: urls, into: nil, context: modelContext, appState: appState)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .background(Color.accentColor.opacity(0.06))
                        .overlay(
                            Label("Drop to add as a new document", systemImage: "doc.badge.plus")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(8)
                                .background(.ultraThinMaterial, in: Capsule())
                        )
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }

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
        .onChange(of: appState.deepLinkDocumentID) { _, id in
            guard let id else { return }
            selectedID = id
            appState.deepLinkDocumentID = nil
        }
        .onChange(of: documents.map(\.id)) { _, _ in
            syncRecentDocumentsToAppGroup()
        }
        .task { syncRecentDocumentsToAppGroup() }
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

    private func syncRecentDocumentsToAppGroup() {
        let recent = documents.prefix(10).map {
            RecentDocumentInfo(id: $0.id, title: $0.title)
        }
        ShareExtensionQueue.updateRecentDocuments(Array(recent))
    }
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let document: TextifyrDocument
    let snippet: String?

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
            if let stage = document.stage {
                StageBadgeView(stage: stage)
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
