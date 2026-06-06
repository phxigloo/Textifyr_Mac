import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct ContentView: View {
    @AppStorage(AppConstants.hasAcceptedTermsKey) private var hasAcceptedTerms = false
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if hasAcceptedTerms {
                MainNavigationView()
            } else {
                DisclaimerView()
            }
        }
        .onOpenURL { url in
            appState.handleDeepLink(url)
        }
        .task {
            // Process any items the Share Extension queued while the app was closed.
            await processShareQueueIfNeeded()
        }
        .onChange(of: appState.pendingShareQueueReady) { _, ready in
            if ready {
                appState.pendingShareQueueReady = false
                Task { await processShareQueueIfNeeded() }
            }
        }
    }

    private func processShareQueueIfNeeded() async {
        guard ShareExtensionQueue.checkHasItems() else { return }
        do {
            let items = try ShareExtensionQueue.dequeueAll()
            for item in items {
                await consumeShareItem(item)
            }
        } catch {
            appState.showError("Could not read shared items: \(error.localizedDescription)")
        }
    }

    private func consumeShareItem(_ item: PendingShareItem) async {
        let document: TextifyrDocument
        if let targetID = item.targetDocumentID {
            let allDocs = (try? modelContext.fetch(FetchDescriptor<TextifyrDocument>())) ?? []
            document = allDocs.first(where: { $0.id == targetID }) ?? makeNewDocument(title: item.sourceTitle)
        } else {
            document = makeNewDocument(title: item.sourceTitle)
        }

        let method = CaptureMethod(rawValue: item.captureMethodRaw) ?? .rtfEditor
        let order = (document.sourceSessions ?? []).count
        let session = SourceSession(captureMethod: method, rawText: item.rawText, sortOrder: order)
        modelContext.insert(session)
        document.sourceSessions = (document.sourceSessions ?? []) + [session]
        document.modificationDate = Date()

        try? modelContext.save()
        appState.selectedDocument = document

        if item.audioFileName != nil {
            appState.showError("'\(item.sourceTitle)' was shared as an audio file. Open the session and use Audio File to transcribe it.")
        }
    }

    private func makeNewDocument(title: String) -> TextifyrDocument {
        let trimmed = title.prefix(80).trimmingCharacters(in: .whitespacesAndNewlines)
        let doc = TextifyrDocument(title: trimmed.isEmpty ? "Shared Content" : trimmed)
        modelContext.insert(doc)
        return doc
    }
}

// MARK: - Main navigation

private struct MainNavigationView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 300)
        } detail: {
            if let doc = appState.selectedDocument {
                DocumentEditorView(document: doc, context: modelContext)
                    .id(doc.id)
            } else {
                EmptyStateView()
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .collapseWindowToolbar()
        .alert("Error", isPresented: Binding(
            get: { appState.alertMessage != nil },
            set: { if !$0 { appState.clearAlert() } }
        )) {
            Button("OK") { appState.clearAlert() }
        } message: {
            Text(appState.alertMessage ?? "")
        }
        .sheet(isPresented: $appState.showPromptBuilder) {
            PromptBuilderView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPipelineEditorSheet)) { _ in
            appState.inspectorVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPromptBuilderSheet)) { _ in
            appState.showPromptBuilder = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            withAnimation {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
    }
}

#Preview {
    let c = makePreviewContainer()
    let appState = previewAppState(selectedIn: c)
    return ContentView()
        .modelContainer(c)
        .environmentObject(appState)
        .frame(width: 1100, height: 700)
}
