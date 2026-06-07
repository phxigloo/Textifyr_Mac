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

    @State private var showingAddSource = false
    @State private var editingSession: SourceSession?
    @State private var editingSmartVision: SourceSession?
    /// Method to auto-open in the picker (set by menu commands and the Share
    /// Extension handoff). Passed directly to the picker so there's no
    /// notification-timing race with the picker's mount.
    @State private var autoSelectMethod: CaptureMethod?

    var body: some View {
        Group {
            if showingAddSource {
                InputSourcePickerView(
                    document: document,
                    context: modelContext,
                    initialMethod: autoSelectMethod,
                    onDismiss: {
                        showingAddSource = false
                        autoSelectMethod = nil
                    }
                )
                .transition(.opacity)
            } else if let session = editingSmartVision {
                SmartVisionEditView(
                    session: session,
                    context: modelContext,
                    onDismiss: { withAnimation { editingSmartVision = nil } }
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
                    onAddSource: { withAnimation { showingAddSource = true } },
                    onEditSession: { session in
                        if session.captureMethod == .smartVision {
                            withAnimation { editingSmartVision = session }
                        } else {
                            withAnimation { editingSession = session }
                        }
                    }
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Handle on appear AND on change. The Share Extension handoff sets
        // pendingSourceMethod while this view is still being mounted (the document
        // was just created and selected), so onChange alone misses it — onAppear
        // catches that case. onChange covers menu commands while already visible.
        .onAppear { handlePendingMethod() }
        .onChange(of: appState.pendingSourceMethod) { _, _ in handlePendingMethod() }
    }

    private func handlePendingMethod() {
        guard let method = appState.pendingSourceMethod else { return }
        appState.pendingSourceMethod = nil
        autoSelectMethod = method
        withAnimation { showingAddSource = true }
    }
}
