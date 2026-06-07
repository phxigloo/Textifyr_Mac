import SwiftUI
import SwiftData
import AppKit
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct RTFOutputView: View {
    @ObservedObject var viewModel: DocumentEditorViewModel
    @Binding var showExportSheet: Bool
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @StateObject private var formatState = TextFormatState()
    @State private var outputInserter = RichTextInserter()
    @State private var isOutputDropTargeted = false

    @Query(filter: #Predicate<FormattingPipeline> { $0.scopeRawValue == "output" },
           sort: \FormattingPipeline.name) private var outputPipelines: [FormattingPipeline]
    @State private var formatBannerDismissed = false
    @State private var isTranslating = false
    @State private var translateTask: Task<Void, Never>? = nil
    @State private var translateError: String? = nil

    @State private var showRefinePanel = false
    @State private var refinePromptText = ""
    @State private var isRefining = false
    @State private var refineTask: Task<Void, Never>? = nil
    @State private var refineProgress: DocumentFormattingService.Progress? = nil
    @State private var refineResult: String? = nil
    @State private var refineError: String? = nil

    private var document: TextifyrDocument { viewModel.document }

    private var estimatedChunkCount: Int {
        let len = document.mergedSourceText.count
        guard len > 0 else { return 0 }
        let chunkSize = ChunkingService.adaptiveChunkSize(for: 400)
        return max(1, Int(ceil(Double(len) / Double(chunkSize))))
    }

    private var showFormatBanner: Bool {
        !document.hasOutput
        && document.pipeline != nil
        && !document.mergedSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !formatBannerDismissed
        && !viewModel.isFormatting
    }

    private var pictureSessions: [SourceSession] {
        (document.sourceSessions ?? [])
            .filter { $0.isPictureSession }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if showFormatBanner {
                formatNudgeBanner
                Divider()
            }
            ZStack {
                contentArea
                if viewModel.isFormatting {
                    formattingOverlay
                }
            }
        }
        .overlay(alignment: .top) {
            if let err = translateError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.primary)
                    Spacer()
                    Button { translateError = nil } label: {
                        Image(systemName: "xmark").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.top, 52)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: translateError != nil)
    }

    // MARK: - Format nudge banner

    private var formatNudgeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text("Sources are ready — tap Format to generate the output.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Format") {
                Task { await viewModel.runFormatting(appState: appState) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                withAnimation { formatBannerDismissed = true }
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
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Header

    private var toolbarSep: some View { Divider().frame(height: 18) }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Output")
                .font(.headline)

            Spacer()

            // ── Section 1: Combine / Clear ────────────────────────────────
            Button {
                viewModel.useMergedSourcesAsOutput()
            } label: {
                Label("Combine", systemImage: "text.append")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(document.mergedSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || viewModel.isFormatting)
            .help("Assemble all sources into the Output without AI formatting")

            if document.hasOutput && !viewModel.isFormatting {
                Button {
                    viewModel.clearOutput()
                } label: {
                    Label("Clear", systemImage: "eraser")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Clear formatted output")
            }

            toolbarSep

            // ── Section 2: Action / Format / Translate ────────────────────
            // Pipeline picker
            Menu {
                ForEach(outputPipelines) { pipeline in
                    Button {
                        viewModel.selectPipeline(pipeline)
                    } label: {
                        HStack {
                            Text(pipeline.name)
                            if document.pipeline?.id == pipeline.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                if !outputPipelines.isEmpty { Divider() }
                Button {
                    appState.inspectorDefaultScope = .output
                    appState.inspectorVisible = true
                } label: {
                    Label("Manage Actions…", systemImage: "slider.horizontal.3")
                }
            } label: {
                HStack(spacing: 4) {
                    Label(
                        document.pipeline?.name ?? "Action",
                        systemImage: "wand.and.sparkles"
                    )
                    if estimatedChunkCount > 1 {
                        Text("~\(estimatedChunkCount)")
                            .foregroundStyle(estimatedChunkCount > 4 ? Color.orange : Color.secondary)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help(estimatedChunkCount > 4
                ? "~\(estimatedChunkCount) chunks — synthesis prompts work better as multi-step actions"
                : "Select a Final Document action")

            // Format / Cancel
            if viewModel.isFormatting {
                ProgressView().controlSize(.small)
                if !viewModel.formattingStep.isEmpty {
                    Text(viewModel.formattingStep)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 160)
                }
                Button("Cancel") {
                    viewModel.cancelFormatting(appState: appState)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button {
                    Task { await viewModel.runFormatting(appState: appState) }
                } label: {
                    Label("Format", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(document.pipeline == nil ||
                          document.mergedSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Run the selected action on all sources")
            }

            // Translate (only when output exists and not currently formatting)
            if document.hasOutput && !viewModel.isFormatting {
                if isTranslating {
                    ProgressView().controlSize(.small)
                    Text("Translating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Cancel") {
                        translateTask?.cancel()
                        translateTask = nil
                        isTranslating = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    TranslateButton(helpText: "Translate the formatted output using AI", bordered: true) { lang in
                        translateOutput(to: lang)
                    }
                }
            }

            // ── Section 3: Export ─────────────────────────────────────────
            if document.hasOutput && !viewModel.isFormatting {
                toolbarSep

                Button {
                    showExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Export document")
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .background(.bar)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        if document.hasOutput {
            VStack(spacing: 0) {
                FormattingToolbar(fmt: formatState)
                Divider()
                RichTextEditor(
                    rtfData: Binding(
                        get: { document.outputRTF },
                        set: { document.outputRTF = $0 }
                    ),
                    isEditable: true,
                    formatState: formatState,
                    inserter: outputInserter,
                    onFileDrop: { urls in
                        OutputDropImporter.handle(urls: urls, document: document,
                                                  inserter: outputInserter, context: modelContext, appState: appState)
                    },
                    onDragTargetingChanged: { isOutputDropTargeted = $0 }
                )
                .overlay {
                    if isOutputDropTargeted {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                            .background(Color.accentColor.opacity(0.05))
                            .overlay(
                                Label("Drop to insert into the document", systemImage: "text.insert")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .padding(10)
                                    .background(.ultraThinMaterial, in: Capsule())
                            )
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
                if !pictureSessions.isEmpty {
                    Divider()
                    pictureStrip
                }
                Divider()
                refinePanel
            }
        } else if !viewModel.isFormatting {
            emptyState
        }
    }

    // MARK: - Picture strip

    private var pictureStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Picture Sources")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text("(\(pictureSessions.count))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Included in RTF export")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(pictureSessions, id: \.id) { session in
                        PictureThumbnailView(session: session)
                    }
                }
                .padding(10)
            }
            .frame(height: 120)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    // MARK: - Formatting overlay

    private var formattingOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)
                if !viewModel.formattingStep.isEmpty {
                    Text(viewModel.formattingStep)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
        }
        .ignoresSafeArea()
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No formatted output yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Select an action and tap Format.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Refine panel

    private var refinePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Refine Output", systemImage: "wand.and.stars")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showRefinePanel.toggle()
                        if !showRefinePanel { refineResult = nil; refineError = nil }
                    }
                } label: {
                    Image(systemName: showRefinePanel ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showRefinePanel.toggle()
                    if !showRefinePanel { refineResult = nil; refineError = nil }
                }
            }

            if showRefinePanel {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if let result = refineResult {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label("Refined Result", systemImage: "wand.and.stars")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Apply") { applyRefineResult(result) }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.mini)
                                Button { refineResult = nil } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            RefineResultText(result)
                                .font(.caption)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    if let err = refineError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }

                    HStack(alignment: .top, spacing: 8) {
                        TextField("Describe a change to make…", text: $refinePromptText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout)
                            .lineLimit(2...3)
                            .disabled(isRefining)

                        if isRefining {
                            VStack(alignment: .leading, spacing: 4) {
                                if let p = refineProgress, p.chunkCount > 1 {
                                    PipelineProgressView(progress: p)
                                        .frame(maxWidth: 160)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                                Button("Cancel") {
                                    refineTask?.cancel()
                                    refineTask = nil
                                    isRefining = false
                                    refineProgress = nil
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.top, 2)
                        } else {
                            Button("Send") { refineOutput() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(refinePromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .padding(.top, 2)
                        }
                    }
                }
                .padding(14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func refineOutput() {
        guard let rtfData = document.outputRTF,
              let attr = NSAttributedString(rtf: rtfData, documentAttributes: nil) else { return }
        let plainText = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plainText.isEmpty else { return }
        isRefining = true
        refineResult = nil
        refineError = nil
        refineProgress = nil
        let prompt = refinePromptText
        refineTask = Task { @MainActor in
            do {
                let result = try await DocumentFormattingService()
                    .formatWithPrompt(sourceText: plainText, systemPrompt: prompt) { p in
                        refineProgress = p
                    }
                if !Task.isCancelled { refineResult = result }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { refineError = error.localizedDescription }
            }
            isRefining = false
            refineProgress = nil
            refineTask = nil
        }
    }

    private func applyRefineResult(_ result: String) {
        let attr = NSAttributedString(
            string: result,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        )
        let range = NSRange(location: 0, length: attr.length)
        if let rtfData = try? attr.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            document.outputRTF = rtfData
        }
        refineResult = nil
        withAnimation { showRefinePanel = false }
    }

    // MARK: - Translation

    private func translateOutput(to language: TranslationLanguage) {
        guard let rtfData = document.outputRTF,
              let attr = NSAttributedString(rtf: rtfData, documentAttributes: nil) else { return }
        let plainText = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plainText.isEmpty else { return }
        isTranslating = true
        translateError = nil
        translateTask = Task { @MainActor in
            do {
                let result = try await DocumentFormattingService()
                    .formatWithPrompt(sourceText: plainText, systemPrompt: language.promptText)
                if !Task.isCancelled {
                    let newAttr = NSAttributedString(
                        string: result,
                        attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
                    )
                    let range = NSRange(location: 0, length: newAttr.length)
                    if let newRTF = try? newAttr.data(
                        from: range,
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                    ) {
                        document.outputRTF = newRTF
                    }
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { translateError = error.localizedDescription }
            }
            isTranslating = false
            translateTask = nil
        }
    }
}

// MARK: - Picture thumbnail

private struct PictureThumbnailView: View {
    let session: SourceSession

    var body: some View {
        VStack(spacing: 4) {
            if let pngData = session.rawRTFData, let nsImage = NSImage(data: pngData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
            }
            if !session.rawText.isEmpty {
                Text(session.previewText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(width: 80)
            }
        }
    }
}

// MARK: - Markdown-aware result text

private struct RefineResultText: View {
    let text: String
    init(_ text: String) { self.text = text }

    private var attributedString: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    var body: some View { Text(attributedString) }
}

#Preview("Empty output") { @MainActor in
    let c = makePreviewContainer()
    let appState = previewAppState(selectedIn: c)
    let vm = previewDocumentVM(in: c)
    return RTFOutputView(viewModel: vm, showExportSheet: .constant(false))
        .modelContainer(c)
        .environmentObject(appState)
        .frame(width: 580, height: 500)
}
