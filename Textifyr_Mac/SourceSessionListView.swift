import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct SourceSessionListView: View {
    let document: TextifyrDocument
    @ObservedObject var viewModel: DocumentEditorViewModel

    @Environment(\.modelContext) private var modelContext
    @State private var selectedSession: SourceSession?
    @State private var showingInputPicker = false
    @State private var editingSession: SourceSession? = nil

    private var sessions: [SourceSession] {
        (document.sourceSessions ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    private var totalCharCount: Int {
        sessions.reduce(0) { $0 + $1.rawText.count }
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
                    selectedSession = nil
                    editingSession = session
                }

                Divider()

                HStack {
                    Text("Total")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if totalCharCount > AppConstants.aiAdvisoryChars {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Large source — AI processing will take longer than usual.")
                    }
                    Spacer()
                    Text("\(totalCharCount.formatted()) chars")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .sheet(isPresented: $showingInputPicker) {
            InputSourcePickerView(document: document, context: modelContext)
        }
        .sheet(item: $editingSession) { session in
            SessionEditSheet(session: session)
        }
    }
}

// MARK: - Session edit sheet

private struct SessionEditSheet: View {
    let session: SourceSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var reviewStepIndex = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: session.captureMethod.systemImage)
                    .foregroundStyle(.tint)
                Text("Edit Session")
                    .font(.title2).bold()
                Spacer()
                stepIndicator
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            CaptureReviewStages(
                originalText: session.rawText,
                initialText: session.rawText,
                isEditMode: true,
                reviewStepIndex: $reviewStepIndex,
                onCancel: { dismiss() },
                onAccept: { finalText in
                    session.rawText = finalText
                    try? modelContext.save()
                    dismiss()
                }
            )
        }
        .frame(width: 600)
    }

    private var stepIndicator: some View {
        // Step 1 is already complete (session was previously acquired); show filled.
        HStack(spacing: 0) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(reviewStepIndex >= i ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: reviewStepIndex == i ? 10 : 7, height: reviewStepIndex == i ? 10 : 7)
                if i < 2 {
                    Rectangle()
                        .fill(reviewStepIndex > i ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 32, height: 2)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: reviewStepIndex)
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
                if session.rawText.count > 0 {
                    Text("\(session.rawText.count.formatted()) chars")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
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
