import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

import UniformTypeIdentifiers

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
    /// Restore (24.1): open the editor straight into the Run-Trace view when a trail crumb asks.
    @State private var pendingShowTrace = false
    /// Method to auto-open in the picker (set by menu commands and the Share
    /// Extension handoff). Passed directly to the picker so there's no
    /// notification-timing race with the picker's mount.
    @State private var autoSelectMethod: CaptureMethod?
    @State private var isDropTargeted = false

    /// Drops are only accepted while the plain source list is showing — not while
    /// a picker, wizard, or editor is open.
    private var isShowingList: Bool {
        !showingAddSource && editingSession == nil && editingSmartVision == nil
    }

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
                        // Let the serial drop queue advance once this wizard closes.
                        DropImportCoordinator.shared.wizardFinished()
                        // Resume a live-capture workflow once its capture completes.
                        resumeLiveWorkflowIfNeeded()
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
                    initialShowTrace: pendingShowTrace,
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
        // Drop files here to add them as sources to THIS document.
        .dropDestination(for: URL.self) { urls, _ in
            guard isShowingList else { return false }
            FileDropImporter.handleDrop(urls: urls, into: document.id, context: modelContext, appState: appState)
            return true
        } isTargeted: { isDropTargeted = $0 && isShowingList }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.accentColor.opacity(0.06))
                    .overlay(
                        Label("Drop to add as sources", systemImage: "plus.rectangle.on.rectangle")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Capsule())
                    )
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        // Handle on appear AND on change. The Share Extension handoff sets
        // pendingSourceMethod while this view is still being mounted (the document
        // was just created and selected), so onChange alone misses it — onAppear
        // catches that case. onChange covers menu commands while already visible.
        .onAppear { handlePendingMethod(); handleSourceEditorRequest() }
        .onChange(of: appState.pendingSourceMethod) { _, _ in handlePendingMethod() }
        .onChange(of: appState.sourceEditorRequest) { _, _ in handleSourceEditorRequest() }
    }

    /// Restores a source editor from a trail crumb (24.1): open the requested source (in Edit
    /// or Run Trace), or close the editor back to the source list.
    private func handleSourceEditorRequest() {
        guard let req = appState.sourceEditorRequest else { return }
        appState.sourceEditorRequest = nil
        switch req {
        case .close:
            withAnimation { editingSession = nil; editingSmartVision = nil }
        case .open(let id, let showTrace):
            guard let session = (document.sourceSessions ?? []).first(where: { $0.id == id }) else { return }
            pendingShowTrace = showTrace
            if session.captureMethod == .smartVision {
                withAnimation { editingSmartVision = session }
            } else {
                withAnimation { editingSession = session }
            }
        }
    }

    private func handlePendingMethod() {
        guard let method = appState.pendingSourceMethod else { return }
        appState.pendingSourceMethod = nil
        autoSelectMethod = method
        withAnimation { showingAddSource = true }
    }

    /// When a live-capture workflow's wizard closes, resume the chain if a source
    /// was actually captured into this document (otherwise treat it as cancelled).
    private func resumeLiveWorkflowIfNeeded() {
        guard let pending = appState.liveWorkflowPending, pending.documentID == document.id else { return }
        appState.liveWorkflowPending = nil
        if !(document.sourceSessions ?? []).isEmpty {
            appState.liveWorkflowResume = pending
        }
    }
}
