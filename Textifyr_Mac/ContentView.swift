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
        // Deep links arrive via the AppDelegate's Apple Event handler (not
        // onOpenURL) so SwiftUI doesn't open a duplicate window for them.
        .onReceive(NotificationCenter.default.publisher(for: .incomingDeepLink)) { note in
            if let url = note.object as? URL {
                appState.handleDeepLink(url)
                Task { await processShareQueueIfNeeded() }
            }
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
        // Belt-and-suspenders: the Share Extension activates this app, so also
        // drain the queue whenever the app becomes active.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await processShareQueueIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileImportFailed)) { note in
            if let msg = note.object as? String { appState.showError(msg) }
        }
    }

    private func processShareQueueIfNeeded() async {
        guard ShareExtensionQueue.checkHasItems() else { return }
        do {
            let items = try ShareExtensionQueue.dequeueAll()
            for item in items {
                ShareIntake.consume(item, context: modelContext, appState: appState)
            }
        } catch {
            appState.showError("Could not read shared items: \(error.localizedDescription)")
        }
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
