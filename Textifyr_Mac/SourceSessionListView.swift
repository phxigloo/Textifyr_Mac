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
    @EnvironmentObject private var appState: AppState

    @Query(filter: #Predicate<FormattingPipeline> { $0.scopeRawValue == "source" },
           sort: \FormattingPipeline.name) private var sourceActions: [FormattingPipeline]
    @State private var showRefineBanner = true
    @State private var showFailuresSummary = true
    @State private var isReordering = false
    @State private var draggingID: UUID? = nil

    private var hasUnrefinedSessions: Bool {
        sessions.contains { !$0.rawText.isEmpty && !$0.hasBeenRefined }
    }

    private var sessions: [SourceSession] {
        (document.sourceSessions ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    private var flaggedSessions: [SourceSession] {
        sessions.filter { $0.lastRunFailed }
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
                if !flaggedSessions.isEmpty { failuresSummaryBanner }

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

    // MARK: - Failures summary banner (21.5)

    /// A lightweight overview of the sources that failed in the last run — not an editor.
    /// Each row jumps to that source's editor (where the failure banner + remedies live),
    /// so discovering and fixing failures share the one per-source editor.
    private var failuresSummaryBanner: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
                Text("\(flaggedSessions.count) of \(sessions.count) need attention")
                    .font(.caption.bold())
                Spacer()
                if document.lastWorkflowPresetID != nil {
                    Button("Re-run Flagged") { rerunFlagged() }
                        .controlSize(.small)
                        .help("Re-run only the flagged sources through this document's workflow, then regenerate the output.")
                }
                Button {
                    withAnimation { showFailuresSummary.toggle() }
                } label: {
                    Image(systemName: showFailuresSummary ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(showFailuresSummary ? "Collapse" : "Show failures")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if showFailuresSummary {
                VStack(spacing: 0) {
                    ForEach(flaggedSessions) { session in
                        Button {
                            onEditSession(session)
                        } label: {
                            HStack(spacing: 6) {
                                Text(session.sourceName.isEmpty ? session.captureMethod.displayName : session.sourceName)
                                    .font(.caption).lineLimit(1)
                                Text("·").foregroundStyle(.tertiary)
                                Text(session.failureRemedy.headline)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .background(Color.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .transition(.opacity)
    }

    private func rerunFlagged() {
        guard let presetID = document.lastWorkflowPresetID else { return }
        appState.rerunFlaggedRequest = LiveWorkflowRequest(presetID: presetID, documentID: document.id)
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
                    if session.lastRunFailed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                            .help(session.lastRunFailureReason.isEmpty
                                  ? "This source failed in the last workflow run — its original text is preserved."
                                  : "Failed: \(session.lastRunFailureReason)")
                    }
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

    @EnvironmentObject private var appState: AppState
    @State private var reviewStepIndex = 1
    /// Hides the failure banner once the user has acted on it (Mark Resolved),
    /// without depending on live @Model observation inside this transient editor.
    @State private var bannerDismissed = false
    /// The source's captured last-run trace (23.2), loaded on appear; nil if never run.
    @State private var trace: RunTrace?
    @State private var showingTrace = false
    /// "Run on This Source" (23.5): apply the failed action to this source and preview the
    /// result before committing — the in-context, action-level re-run.
    @State private var tryState: TryState = .idle
    @State private var tryActionName = ""
    @State private var rebuildHintShown = false

    private enum TryState: Equatable {
        case idle, running
        case result(String)
        case failed(String)
        var isActive: Bool { self != .idle }
    }

    private var showFailureBanner: Bool { session.lastRunFailed && !bannerDismissed }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if showingTrace {
                    Button { withAnimation { showingTrace = false } } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Back to editing")
                }
                Image(systemName: showingTrace ? "list.bullet.rectangle" : session.captureMethod.systemImage)
                    .foregroundStyle(.tint)
                Text(showingTrace ? "Run Trace" : "Edit Session")
                    .font(.title2).bold()
                Spacer()
                if showingTrace {
                    EmptyView()
                } else {
                    if trace != nil {
                        Button { withAnimation { showingTrace = true } } label: {
                            Label("Inspect Run", systemImage: "list.bullet.rectangle")
                        }
                        .controlSize(.small)
                        .help("See what each step did to this source in the last run.")
                    }
                    stepIndicator
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            if showingTrace, let trace {
                RunTraceInspectorView(trace: trace,
                                      onOpenStepEditor: openStepEditor,
                                      onRerunFromHere: rerunFromHere)
            } else if tryState.isActive {
                tryRunPanel
            } else {
                editorContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.wizardDismiss, onDismiss)
        .onAppear {
            trace = RunTraceStore.read(sourceID: session.id)
            updateSourceBreadcrumb()
        }
        .onChange(of: showingTrace) { _, _ in updateSourceBreadcrumb() }
        .onDisappear {
            // Restore the document-level breadcrumb when simply closing the editor; if we
            // navigated into another tool, that tool already set its own trail (23.4).
            if appState.workspaceMode == .documents {
                appState.breadcrumb = [
                    BreadcrumbCrumb("Documents", targetMode: .documents),
                    BreadcrumbCrumb(session.document?.title ?? "Document", targetMode: .documents),
                ]
            }
        }
    }

    /// Pushes the source-editor location into the Path Bar (23.4 / #2):
    /// `Documents ▸ <doc> ▸ <source> ▸ Edit` — or `▸ Run Trace` while inspecting.
    private func updateSourceBreadcrumb() {
        let docTitle = session.document?.title ?? ""
        let srcName = session.sourceName.isEmpty ? session.captureMethod.displayName : session.sourceName
        appState.breadcrumb = [
            BreadcrumbCrumb("Documents", targetMode: .documents),
            BreadcrumbCrumb(docTitle.isEmpty ? "Document" : docTitle, targetMode: .documents),
            BreadcrumbCrumb(srcName),
            BreadcrumbCrumb(showingTrace ? "Run Trace" : "Edit"),
        ]
    }

    @ViewBuilder
    private var editorContent: some View {
        VStack(spacing: 0) {
            if rebuildHintShown { rebuildHintBar }
            if showFailureBanner { failureBanner }

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
                    // A flagged source that's edited still needs the action run on it — keep it
                    // flagged as "awaiting re-run" (Re-run Flagged will process it) rather than
                    // silently clearing. "Mark Resolved" is the explicit "this text is final" path.
                    markAwaitingRerunIfFlagged(session)
                    try? context.save()
                    onDismiss()
                },
                onAcceptSplit: { parts in
                    let wasFlagged = session.lastRunFailed
                    let first = parts[0]
                    session.rawText    = first.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    session.rawRTFData = first.rtf(from: NSRange(location: 0, length: first.length),
                                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                    markAwaitingRerunIfFlagged(session)
                    for part in parts.dropFirst() {
                        let order      = (session.document?.sourceSessions ?? []).count
                        let newSession = SourceSession(captureMethod: session.captureMethod,
                                                      rawText: part.string.trimmingCharacters(in: .whitespacesAndNewlines),
                                                      sortOrder: order)
                        newSession.rawRTFData = part.rtf(from: NSRange(location: 0, length: part.length),
                                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                        // Pieces split from a flagged source still need the action run on them.
                        if wasFlagged {
                            newSession.lastRunFailed = true
                            newSession.lastRunFailureReason = "Awaiting processing after split."
                        }
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

    // MARK: - Failure banner (21.5)

    /// Shown when this source failed in the last workflow run. Names the error in plain
    /// language, suggests the matching remedy, and offers one-click routes to fix it:
    /// edit/split here, open the action, or iterate the prompt in the Prompt Builder.
    private var failureBanner: some View {
        let remedy = session.failureRemedy
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: remedy.icon)
                    .foregroundStyle(remedy == .awaitingRerun ? Color.accentColor : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(remedy.headline)
                        .font(.callout.bold())
                    Text(remedy.guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !session.lastRunFailureReason.isEmpty {
                        Text(session.lastRunFailureReason)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            HStack(spacing: 8) {
                // For "awaiting re-run" the input is already fixed — re-running happens from
                // the Sources list, so just offer "Mark Resolved" (this text is final).
                if trace != nil {
                    Button("Inspect Run") { withAnimation { showingTrace = true } }
                        .controlSize(.small)
                        .help("See each step's input and output, positioned at the failure.")
                }
                // Kind-aware route to the failed step's editor (23.3): AI step → Prompt
                // Builder; deterministic step → the Action editor. Falls back to the generic
                // routes when we have no structured provenance.
                if let prov = session.failureProvenance {
                    // In-context, action-level re-run (23.5): apply the failed action to this
                    // source's current text and preview before committing.
                    Button("Run on This Source") { runActionOnSource(prov) }
                        .controlSize(.small)
                        .help("Run “\(prov.actionName)” on this source and preview the result.")
                    if remedy != .awaitingRerun {
                        switch StepEditRoute.from(kindRaw: prov.stepKind) {
                        case .promptBuilder:
                            Button("Improve in Prompt Builder") { improveFailedStep(prov) }
                                .controlSize(.small)
                        case .actionEditor:
                            Button("Open the Action") { openAction(prov.actionID) }
                                .controlSize(.small)
                        }
                    }
                } else if remedy != .noText && remedy != .awaitingRerun {
                    Button("Open the Action") { openActions() }
                        .controlSize(.small)
                    Button("Improve in Prompt Builder") { openInPromptBuilder() }
                        .controlSize(.small)
                }
                Spacer()
                Button("Mark Resolved") { markResolved() }
                    .controlSize(.small)
                    .help("Clear the flag — this text is final; don't run the action on it.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .transition(.opacity)
    }

    private func clearFailureFlag() {
        session.lastRunFailed = false
        session.lastRunFailureReason = ""
        session.failureProvenance = nil
    }

    /// After editing a *flagged* source, keep it flagged but switch it to the softer
    /// "awaiting re-run" state — the input is fixed, but the action still has to run.
    /// Provenance is *kept* so "Run on This Source" knows which action to apply (23.5).
    private func markAwaitingRerunIfFlagged(_ session: SourceSession) {
        guard session.lastRunFailed else { return }
        session.lastRunFailureReason = "Awaiting processing after edit."
    }

    private func markResolved() {
        clearFailureFlag()
        try? context.save()
        withAnimation { bannerDismissed = true }
    }

    /// Records the document/source as the cascade root (23.4) so drilling into a tool keeps
    /// `📄 <doc> ▸ <source>` at the head of the breadcrumb instead of losing the source.
    private func setEditOrigin() {
        appState.editOrigin = EditOrigin(
            documentTitle: session.document?.title ?? "",
            sourceName: session.sourceName.isEmpty ? session.captureMethod.displayName : session.sourceName)
    }

    private func openActions() {
        setEditOrigin()
        appState.workspaceMode = .actions
        onDismiss()
    }

    private func openInPromptBuilder() {
        setEditOrigin()
        appState.promptBuilderSeed = PromptBuilderSeed(
            prompt: "",
            sampleText: session.rawText,
            sampleName: session.sourceName.isEmpty ? session.captureMethod.displayName : session.sourceName)
        appState.workspaceMode = .promptBuilder
        onDismiss()
    }

    /// Kind-aware routing (23.3): open a traced step in the *right* editor. AI step →
    /// Prompt Builder, seeded with its prompt + this run's real input; deterministic step
    /// (Extract Fields / transform) → the Action editor, navigated to that action.
    private func openStepEditor(_ record: StepTraceRecord) {
        setEditOrigin()
        switch record.editRoute {
        case .promptBuilder:
            appState.promptBuilderSeed = PromptBuilderSeed(
                prompt: prompt(forAction: record.actionID, stepIndex: record.stepIndex),
                actionID: record.actionID,
                stepIndex: record.stepIndex,
                sampleText: record.input,
                sampleName: "Step: \(record.stepName)")
            appState.workspaceMode = .promptBuilder
        case .actionEditor:
            appState.actionToOpen = record.actionID
            appState.workspaceMode = .actions
        }
        onDismiss()
    }

    /// Opens a failed deterministic step's action in the Action editor (23.3).
    private func openAction(_ id: UUID) {
        setEditOrigin()
        appState.actionToOpen = id
        appState.workspaceMode = .actions
        onDismiss()
    }

    /// Improves a failed AI step's prompt in the Prompt Builder, staging the exact input
    /// that failed (pulled from the trace) as the test sample (23.3).
    private func improveFailedStep(_ prov: FailureProvenance) {
        setEditOrigin()
        appState.promptBuilderSeed = PromptBuilderSeed(
            prompt: prompt(forAction: prov.actionID, stepIndex: prov.stepIndex),
            actionID: prov.actionID,
            stepIndex: prov.stepIndex,
            sampleText: trace?.steps.first(where: { $0.failed })?.input ?? session.rawText,
            sampleName: "Step: \(prov.stepName)")
        appState.workspaceMode = .promptBuilder
        onDismiss()
    }

    /// The current prompt text of a step (looked up live so the user edits today's action).
    private func prompt(forAction id: UUID, stepIndex: Int) -> String {
        let pipelines = (try? context.fetch(FetchDescriptor<FormattingPipeline>())) ?? []
        guard let p = pipelines.first(where: { $0.id == id }) else { return "" }
        let steps = p.sortedSteps
        guard stepIndex >= 0, stepIndex < steps.count else { return "" }
        return steps[stepIndex].prompt
    }

    // MARK: - Run on This Source (in-context action re-run, 23.5)

    private func fetchAction(_ id: UUID) -> FormattingPipeline? {
        ((try? context.fetch(FetchDescriptor<FormattingPipeline>())) ?? []).first { $0.id == id }
    }

    /// Runs the failed action on this source's *current* text and previews the result —
    /// the precise re-run (only the action that failed, not the whole source chain).
    private func runActionOnSource(_ prov: FailureProvenance) {
        guard let action = fetchAction(prov.actionID) else { return }
        runTraced(action: action, name: prov.actionName, input: session.rawText, range: nil)
    }

    /// "Re-run from here" (23.7): recompute the action from a trace step forward on its
    /// captured input, with today's (possibly just-edited) action — confirm a fix reaches
    /// the output. Result feeds the same preview (Use This & Save writes the source).
    private func rerunFromHere(_ record: StepTraceRecord) {
        guard let action = fetchAction(record.actionID) else { return }
        showingTrace = false
        runTraced(action: action, name: record.actionName, input: record.input,
                  range: record.stepIndex..<Int.max)
    }

    private func runTraced(action: FormattingPipeline, name: String, input: String, range: Range<Int>?) {
        tryActionName = name
        tryState = .running
        Task { @MainActor in
            do {
                let result = try await DocumentFormattingService()
                    .runTraced(pipeline: action, sourceText: input, range: range)
                tryState = result.failedStep.map { .failed($0.reason) } ?? .result(result.finalText)
            } catch {
                tryState = .failed(error.localizedDescription)
            }
        }
    }

    /// Commits a previewed result to the source, clears the flag, and notes that the
    /// document output now needs rebuilding (output assembly stays workflow-level, 23.5).
    private func useTryResult(_ output: String) {
        session.rawText = output
        session.rawRTFData = nil
        clearFailureFlag()
        try? context.save()
        tryState = .idle
        withAnimation { rebuildHintShown = true }
    }

    @ViewBuilder
    private var tryRunPanel: some View {
        switch tryState {
        case .running:
            VStack(spacing: 12) {
                ProgressView()
                Text("Running “\(tryActionName)” on this source…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .result(let output):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Result of “\(tryActionName)”").font(.headline)
                    Spacer()
                    Button("Discard") { tryState = .idle }
                        .controlSize(.small)
                    Button("Use This & Save") { useTryResult(output) }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
                Divider()
                ScrollView {
                    Text(output.isEmpty ? "—" : output)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        case .failed(let reason):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle).foregroundStyle(.orange)
                Text("Still failed").font(.headline)
                Text(reason).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Back") { tryState = .idle }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
        case .idle:
            EmptyView()
        }
    }

    private var rebuildHintBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Saved. Rebuild the final document / export to include this change.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { withAnimation { rebuildHintShown = false } } label: {
                Image(systemName: "xmark").font(.caption2).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color.green.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
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
