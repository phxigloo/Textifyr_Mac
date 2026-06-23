import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct SourceSessionListView: View {
    let document: TextifyrDocument
    @ObservedObject var viewModel: DocumentEditorViewModel
    var onAddSource:   () -> Void = {}
    var onEditSession: (SourceSession) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<FormattingPipeline> { $0.scopeRawValue == "source" },
           sort: \FormattingPipeline.name) private var sourceActions: [FormattingPipeline]
    @State private var showRefineBanner = true
    @State private var isReordering = false
    @State private var draggingID: UUID? = nil

    private var hasUnrefinedSessions: Bool {
        sessions.contains { !$0.rawText.isEmpty && !$0.hasBeenRefined }
    }

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
                    withAnimation { isReordering.toggle() }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(isReordering ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(isReordering ? "Done reordering" : "Reorder sources")
                .disabled(sessions.count < 2)

                Button {
                    onAddSource()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add source")
                .disabled(isReordering)
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
                    Button("Add Source") { onAddSource() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sessions) { session in
                        SessionRowView(session: session, showHandle: isReordering)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !isReordering else { return }
                                onEditSession(session)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    viewModel.deleteSession(session)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                if !isReordering {
                                    Button("Edit") { onEditSession(session) }
                                    Divider()
                                }
                                Button("Delete", role: .destructive) { viewModel.deleteSession(session) }
                            }
                            .onDrag {
                                draggingID = session.id
                                return NSItemProvider(object: session.id.uuidString as NSString)
                            }
                            .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                                guard isReordering,
                                      let fromID = draggingID,
                                      let fromIndex = sessions.firstIndex(where: { $0.id == fromID }),
                                      let toIndex = sessions.firstIndex(where: { $0.id == session.id }),
                                      fromIndex != toIndex else { return false }
                                var arr = sessions
                                arr.move(fromOffsets: IndexSet(integer: fromIndex),
                                         toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
                                viewModel.reorderSessions(arr)
                                draggingID = nil
                                return true
                            }
                    }
                }
                .listStyle(.sidebar)

                if hasUnrefinedSessions && !sourceActions.isEmpty && showRefineBanner {
                    refineBanner
                }

                Divider()

                HStack(spacing: 6) {
                    Spacer()
                    if totalCharCount > AppConstants.aiAdvisoryChars {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Large source — AI processing will take longer than usual.")
                    }
                    Text("Total")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(totalCharCount.formatted()) chars")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 34)          // match the master +/- footer height
                .background(.bar)
            }
        }
    }

    // MARK: - Refine banner

    private var refineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text("Sources can be refined in the Chat tab before combining.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation { showRefineBanner = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.07))
        .transition(.opacity)
    }
}

// MARK: - Session row

private struct SessionRowView: View {
    let session: SourceSession
    var showHandle: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if showHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)
            }
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
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Session edit (inline, no sheet)

struct SessionEditView: View {
    let session: SourceSession
    let context: ModelContext
    let onDismiss: () -> Void

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
                initialRTFData: session.rawRTFData,
                isEditMode: true,
                reviewStepIndex: $reviewStepIndex,
                onCancel: { onDismiss() },
                onAccept: { finalText, rtfData in
                    session.rawText = finalText
                    if let rtf = rtfData { session.rawRTFData = rtf }
                    try? context.save()
                    onDismiss()
                },
                onAcceptSplit: { parts in
                    let first = parts[0]
                    session.rawText    = first.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    session.rawRTFData = first.rtf(from: NSRange(location: 0, length: first.length),
                                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                    for part in parts.dropFirst() {
                        let order      = (session.document?.sourceSessions ?? []).count
                        let newSession = SourceSession(captureMethod: session.captureMethod,
                                                      rawText: part.string.trimmingCharacters(in: .whitespacesAndNewlines),
                                                      sortOrder: order)
                        newSession.rawRTFData = part.rtf(from: NSRange(location: 0, length: part.length),
                                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                        context.insert(newSession)
                        newSession.document = session.document
                        session.document?.sourceSessions = (session.document?.sourceSessions ?? []) + [newSession]
                    }
                    session.document?.modificationDate = Date()
                    try? context.save()
                    onDismiss()
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.wizardDismiss, onDismiss)
    }

    private var stepIndicator: some View {
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

#Preview { @MainActor in
    let c = makePreviewContainer()
    let doc = previewDocument(in: c)
    let vm = previewDocumentVM(in: c)
    return SourceSessionListView(document: doc, viewModel: vm)
        .modelContainer(c)
        .environmentObject(AppState())
        .frame(width: 400, height: 500)
}
