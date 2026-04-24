import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TextifyrDocument.sortOrder) private var documents: [TextifyrDocument]

    @State private var searchText = ""
    @State private var selectedID: UUID?

    private var filtered: [TextifyrDocument] {
        guard !searchText.isEmpty else { return documents }
        return documents.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List(filtered, id: \.id, selection: $selectedID) { doc in
            SidebarRow(document: doc)
                .tag(doc.id)
                .contextMenu {
                    Button("Delete", role: .destructive) { delete(doc) }
                }
        }
        .searchable(text: $searchText, placement: .sidebar)
        .navigationTitle("Documents")
        .toolbar {
            ToolbarItem {
                Button { createDocument() } label: {
                    Label("New Document", systemImage: "plus")
                }
                .help("New Document (⌘N)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newDocument)) { _ in
            createDocument()
        }
        // Sync local selection → appState (deferred to avoid mutating during view update)
        .onChange(of: selectedID) { _, id in
            appState.selectedDocument = documents.first { $0.id == id }
        }
        // Sync appState → local selection (e.g. when new document is created)
        .onChange(of: appState.selectedDocument?.id) { _, id in
            if selectedID != id { selectedID = id }
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
        modelContext.delete(doc)
        try? modelContext.save()
    }
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let document: TextifyrDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(document.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                if let stage = document.stage {
                    StageBadgeView(stage: stage)
                }
            }
            Text(document.modificationDate, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
