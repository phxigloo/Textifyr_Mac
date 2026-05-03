import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

struct SourceSessionListView: View {
    let document: TextifyrDocument
    @ObservedObject var viewModel: DocumentEditorViewModel

    @Environment(\.modelContext) private var modelContext
    @State private var selectedSession: SourceSession?
    @State private var showingInputPicker = false

    // Microphone sessions open the wizard in edit mode instead of SessionDetailView
    @State private var editingMicSession: SourceSession? = nil

    private var sessions: [SourceSession] {
        (document.sourceSessions ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("Sources")
                    .font(.headline)
                Spacer()
                Button {
                    showingInputPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add source")
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
            .background(.bar)

            Divider()

            if sessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No sources yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Add Source") { showingInputPicker = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(sessions, id: \.id, selection: $selectedSession) { session in
                    SessionRowView(session: session)
                        .tag(session)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                if selectedSession?.id == session.id { selectedSession = nil }
                                viewModel.deleteSession(session)
                            }
                        }
                }
                .listStyle(.sidebar)
                .onChange(of: selectedSession) { _, session in
                    guard let session else { return }
                    if session.captureMethod == .microphone {
                        selectedSession = nil
                        editingMicSession = session
                    }
                }
            }
        }
        .sheet(isPresented: $showingInputPicker) {
            InputSourcePickerView(document: document, context: modelContext)
        }
        .sheet(item: $selectedSession) { session in
            SessionDetailView(session: session, document: document)
        }
        .sheet(item: $editingMicSession) { session in
            MicrophoneEditSheet(session: session, document: document, context: modelContext)
        }
    }
}

// MARK: - Microphone edit sheet

private struct MicrophoneEditSheet: View {
    let session: SourceSession
    let document: TextifyrDocument
    @StateObject private var captureVM: InputCaptureViewModel

    init(session: SourceSession, document: TextifyrDocument, context: ModelContext) {
        self.session = session
        self.document = document
        _captureVM = StateObject(wrappedValue: InputCaptureViewModel(document: document, context: context))
    }

    var body: some View {
        MicrophoneWizardView(captureVM: captureVM, initialSession: session)
    }
}

// MARK: - Session row

private struct SessionRowView: View {
    let session: SourceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: session.captureMethod.systemImage)
                    .foregroundStyle(Color.accentColor)
                Text(session.captureMethod.displayName)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if session.containsCopyrightNotice {
                    Image(systemName: "c.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption2)
                        .help("This session may contain copyrighted material")
                }
                Text(session.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !session.rawText.isEmpty {
                Text(session.previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let doc = previewDocument(in: c)
    let vm = previewDocumentVM(in: c)
    return SourceSessionListView(document: doc, viewModel: vm)
        .modelContainer(c)
        .environmentObject(AppState())
        .frame(width: 320, height: 500)
}
