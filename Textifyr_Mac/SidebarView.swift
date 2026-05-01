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
    @State private var showDeleteConfirmation = false
    @State private var documentToDelete: TextifyrDocument?

    private var filtered: [TextifyrDocument] {
        guard !searchText.isEmpty else { return documents }
        return documents.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var selectedDocument: TextifyrDocument? {
        guard let id = selectedID else { return nil }
        return documents.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(filtered, id: \.id, selection: $selectedID) { doc in
                SidebarRow(document: doc)
                    .tag(doc.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            documentToDelete = doc
                            showDeleteConfirmation = true
                        }
                    }
            }
            .searchable(text: $searchText, placement: .sidebar)
            .listStyle(.sidebar)
            .navigationTitle("")

            Divider()

            // + / - footer (mirrors the Settings pipeline list pattern)
            HStack(spacing: 2) {
                Button {
                    createDocument()
                } label: {
                    Image(systemName: "plus")
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
                }
                .buttonStyle(.borderless)
                .disabled(selectedDocument == nil)
                .help("Delete selected document")

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
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
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkStage.sortOrder) private var stages: [WorkStage]

    var body: some View {
        HStack {
            Text(document.title)
                .font(.body)
                .lineLimit(1)
            Spacer()
            // Stage badge: visual is drawn separately so Menu chrome doesn't affect colors
            if let stage = document.stage {
                ZStack {
                    StageBadgeView(stage: stage)
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
                        Color.clear.contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
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

#Preview("Sidebar with documents") {
    let c = makePreviewContainer()
    let appState = previewAppState(selectedIn: c)
    return SidebarView()
        .modelContainer(c)
        .environmentObject(appState)
        .frame(width: 260, height: 500)
}
