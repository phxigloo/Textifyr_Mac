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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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
            }
        }
        .sheet(isPresented: $showingInputPicker) {
            InputSourcePickerView(document: document, context: modelContext)
        }
        .sheet(item: $selectedSession) { session in
            SessionDetailView(session: session, document: document)
        }
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
