import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

/// Manages the Sources tab: shows the session list normally, and replaces it
/// inline (no sheet) with the input picker or session editor when active.
struct SourcesTabView: View {
    let document: TextifyrDocument
    @ObservedObject var viewModel: DocumentEditorViewModel
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState

    @State private var showingAddSource  = false
    @State private var editingSession: SourceSession?

    var body: some View {
        Group {
            if showingAddSource {
                InputSourcePickerView(
                    document: document,
                    context: modelContext,
                    onDismiss: { showingAddSource = false }
                )
                .transition(.opacity)
            } else if let session = editingSession {
                SessionEditView(
                    session: session,
                    context: modelContext,
                    onDismiss: { editingSession = nil }
                )
                .transition(.opacity)
            } else {
                SourceSessionListView(
                    document: document,
                    viewModel: viewModel,
                    onAddSource:   { withAnimation { showingAddSource = true } },
                    onEditSession: { session in withAnimation { editingSession = session } }
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
