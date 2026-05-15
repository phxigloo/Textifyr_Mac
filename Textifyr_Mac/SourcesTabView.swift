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

    var body: some View {
        Group {
            if showingAddSource {
                InputSourcePickerView(
                    document: document,
                    context: modelContext,
                    onDismiss: { showingAddSource = false }
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
        .onChange(of: appState.pendingSourceMethod) { _, method in
            guard let method else { return }
            appState.pendingSourceMethod = nil
            withAnimation { showingAddSource = true }
            // The picker grid will open; InputSourcePickerView reads activeMethod
            // from the environment. We post a notification so it can auto-select.
            NotificationCenter.default.post(
                name: .triggerSourceMethod,
                object: method.displayName
            )
        }
    }
}

extension Notification.Name {
    static let triggerSourceMethod = Notification.Name("TextifyrTriggerSourceMethod")
}
