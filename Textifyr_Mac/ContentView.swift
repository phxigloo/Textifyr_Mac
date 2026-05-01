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
        if hasAcceptedTerms {
            MainNavigationView()
        } else {
            DisclaimerView()
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
