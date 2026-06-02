import SwiftUI
import SwiftData
import AppKit
import Combine
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

// MARK: - Dictation support

final class TextInsertionProxy: ObservableObject {
    var insertAtCursor: ((String) -> Void)?
    var startDictation: (() -> Void)?
    var updateDictation: ((String) -> Void)?
    var endDictation: (() -> Void)?
}

@MainActor
final class DictationHolder: ObservableObject {
    let service = SpeechCaptureService()
    @Published var isActive = false
    @Published var level: Float = 0

    var proxy: TextInsertionProxy?

    private var levelTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var volatileTask: Task<Void, Never>?

    func start() async throws {
        let streams = try await service.startCapture()
        isActive = true
        proxy?.startDictation?()

        levelTask = Task { [weak self] in
            for await l in streams.levels { self?.level = l }
        }

        volatileTask = Task { [weak self] in
            for await text in streams.volatileText {
                guard !text.isEmpty else { continue }
                self?.proxy?.updateDictation?(text)
            }
            self?.proxy?.endDictation?()
        }
        finalTask = Task { [weak self] in
            for await _ in streams.finalSegments {
                self?.proxy?.endDictation?()
                self?.proxy?.startDictation?()
            }
        }
    }

    func stop() async {
        _ = await service.stopCapture()
        levelTask?.cancel();    levelTask = nil
        finalTask?.cancel();    finalTask = nil
        volatileTask?.cancel(); volatileTask = nil
        isActive = false
        level = 0
        proxy = nil
    }

    func cancel() {
        service.cancelCapture()
        levelTask?.cancel();    levelTask = nil
        finalTask?.cancel();    finalTask = nil
        volatileTask?.cancel(); volatileTask = nil
        isActive = false
        level = 0
        proxy = nil
    }
}

// NSViewRepresentable text editor that exposes cursor-position insertion
// via TextInsertionProxy. SwiftUI's TextEditor does not support insertText
// at the selection point; this wraps NSTextView directly.
struct DictationAwareTextEditor: NSViewRepresentable {
    @Binding var text: String
    let proxy: TextInsertionProxy

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.string = text
        context.coordinator.connect(textView: textView, proxy: proxy)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        guard textView.string != text else { return }
        let sel = textView.selectedRange()
        textView.string = text
        let safeLocation = min(sel.location, (text as NSString).length)
        textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        private weak var connectedTextView: NSTextView?
        private var dictationStart: Int? = nil
        private var dictationInsertedLength: Int = 0

        init(text: Binding<String>) { _text = text }

        func connect(textView: NSTextView, proxy: TextInsertionProxy) {
            connectedTextView = textView

            proxy.insertAtCursor = { [weak self] inserted in
                guard let tv = self?.connectedTextView else { return }
                tv.insertText(inserted, replacementRange: tv.selectedRange())
            }

            proxy.startDictation = { [weak self] in
                guard let self, let tv = self.connectedTextView else { return }
                self.dictationStart = tv.selectedRange().location
                self.dictationInsertedLength = 0
            }

            proxy.updateDictation = { [weak self] newText in
                guard let self, let tv = self.connectedTextView,
                      let start = self.dictationStart else { return }
                let range = NSRange(location: start, length: self.dictationInsertedLength)
                tv.insertText(newText, replacementRange: range)
                self.dictationInsertedLength = (newText as NSString).length
            }

            proxy.endDictation = { [weak self] in
                self?.dictationStart = nil
                self?.dictationInsertedLength = 0
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text = tv.string
        }
    }
}

// MARK: - Markdown-aware text view

struct MarkdownOrPlainText: View {
    let text: String
    init(_ text: String) { self.text = text }

    private var attributedString: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    var body: some View {
        Text(attributedString)
    }
}

// MARK: - Pipeline run record

struct PipelineRun: Identifiable {
    let id = UUID()
    let pipelineName: String
    let result: String       // plain text for AI chaining
    var resultRTF: Data?     // RTF for the editable bubble
    var isTransferred = false
}

struct PipelineRunBubble: View {
    @Binding var run: PipelineRun
    let onTransfer: () -> Void
    var onDelete: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(run.pipelineName, systemImage: "wand.and.sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if run.isTransferred {
                    Label("Applied", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Button("Apply", action: onTransfer)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    if let onDelete {
                        Button(action: onDelete) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this result")
                    }
                }
            }

            Group {
                let lineCount = run.result.components(separatedBy: "\n").count
                if lineCount > 25 {
                    ScrollView {
                        MarkdownOrPlainText(run.result)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(6)
                    }
                    .frame(maxHeight: 420)
                } else {
                    MarkdownOrPlainText(run.result)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Pipeline progress indicator

struct PipelineProgressView: View {
    let progress: DocumentFormattingService.Progress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    if progress.stepCount > 1 {
                        Text("Step \(progress.stepIndex + 1) of \(progress.stepCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(progress.stepName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if progress.chunkIndex == 0 {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                ProgressView(value: Double(progress.chunkIndex), total: Double(progress.chunkCount))
                    .progressViewStyle(.linear)
                    .animation(.linear(duration: 0.2), value: progress.chunkIndex)
            }
            if progress.chunkCount > 1 {
                let partLabel = progress.chunkIndex == 0
                    ? "Processing part 1 of \(progress.chunkCount)…"
                    : "Part \(min(progress.chunkIndex + 1, progress.chunkCount)) of \(progress.chunkCount)"
                Text(partLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Shared wizard stages (single RTF step)

/// Single review stage shared across all input wizards.
/// The outer wizard owns the header/step-indicator; this view owns only the body content.
/// - `reviewStepIndex`: kept for backward compat; always set to 1 on appear.
/// - `onBack`: called when the user taps Back; nil in edit-mode contexts.
/// - `onCancel`: outer wizard cleans up any in-progress capture and dismisses.
/// - `onAccept`: outer wizard receives the final plain text + optional RTF data, saves to the session, and dismisses.
struct CaptureReviewStages: View {
    let originalText: String
    private let initialText: String
    private let initialRTFData: Data?
    let isEditMode: Bool
    let showAutoStoppedBanner: Bool
    @Binding var reviewStepIndex: Int
    var onBack: (() -> Void)?
    let onCancel: () -> Void
    let onAccept: (String, Data?) -> Void
    var onAcceptSplit: (([NSAttributedString]) -> Void)? = nil

    @Query(filter: #Predicate<FormattingPipeline> { $0.scopeRawValue == "source" },
           sort: \FormattingPipeline.name) private var sourcePipelines: [FormattingPipeline]

    @EnvironmentObject private var appState: AppState

    @AppStorage("textifyr.aiExpanded")  private var aiExpanded:  Bool = false
    @AppStorage("textifyr.focusMode")   private var focusMode:   Bool = false

    @State private var sourceRTFData: Data? = nil
    @StateObject private var editorFormatState = TextFormatState()
    @StateObject private var dictation = DictationHolder()

    @State private var selectedSourcePipelineID: PersistentIdentifier? = nil
    @State private var pipelineRuns: [PipelineRun] = []
    @State private var isRunningPipeline = false
    @State private var runningPipelineTask: Task<Void, Never>? = nil
    @State private var pipelineProgress: DocumentFormattingService.Progress? = nil
    @State private var errorText: String? = nil
    @State private var freeformPromptText = ""
    @State private var isRunningFreeform = false
    @State private var runningFreeformTask: Task<Void, Never>? = nil
    @State private var freeformProgress: DocumentFormattingService.Progress? = nil

    @State private var isTranslating = false
    @State private var translateTask: Task<Void, Never>? = nil
    @State private var splitSheetRTFData: Data? = nil

    private static let splitThreshold = 50_000

    init(
        originalText: String,
        initialText: String,
        initialRTFData: Data? = nil,
        isEditMode: Bool,
        showAutoStoppedBanner: Bool = false,
        reviewStepIndex: Binding<Int>,
        onBack: (() -> Void)? = nil,
        onCancel: @escaping () -> Void,
        onAccept: @escaping (String, Data?) -> Void,
        onAcceptSplit: (([NSAttributedString]) -> Void)? = nil
    ) {
        self.originalText = originalText
        self.initialText = initialText
        self.initialRTFData = initialRTFData
        self.isEditMode = isEditMode
        self.showAutoStoppedBanner = showAutoStoppedBanner
        _reviewStepIndex = reviewStepIndex
        self.onBack = onBack
        self.onCancel = onCancel
        self.onAccept = onAccept
        self.onAcceptSplit = onAcceptSplit
    }

    var body: some View {
        reviewView
            .onAppear { initializeRTF() }
            .sheet(isPresented: Binding(get: { splitSheetRTFData != nil },
                                        set: { if !$0 { splitSheetRTFData = nil } })) {
                if let data = splitSheetRTFData, let handler = onAcceptSplit {
                    SourceSplitSheet(rtfData: data) { parts in
                        splitSheetRTFData = nil
                        handler(parts)
                    } onCancel: {
                        splitSheetRTFData = nil
                    }
                }
            }
    }

    // MARK: - RTF initialization

    private func initializeRTF() {
        guard sourceRTFData == nil else { return }
        if let rtf = initialRTFData {
            // In edit mode the stored RTF was already processed/formatted on first capture,
            // so use it as-is. In capture mode the RTF editor passes raw RTF whose text may
            // contain markdown literals (e.g. "## Header", "**bold**") — detect and convert
            // those so the review step opens with proper formatting.
            if !isEditMode,
               let attr = NSAttributedString(rtf: rtf, documentAttributes: nil),
               looksLikeMarkdown(attr.string) {
                sourceRTFData = textToRTF(attr.string) ?? rtf
            } else {
                sourceRTFData = rtf
            }
        } else {
            sourceRTFData = textToRTF(initialText)
        }
        reviewStepIndex = 1
    }

    // MARK: - Review view

    private var reviewView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    if showAutoStoppedBanner {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.badge.exclamationmark.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text("Recording was auto-stopped at the 2-hour limit.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    }

                    // Header row
                    HStack(alignment: .firstTextBaseline) {
                        Text("Source")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let data = sourceRTFData,
                           let attr = NSAttributedString(rtf: data, documentAttributes: nil) {
                            Text("\(attr.string.count.formatted()) chars")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            sourceRTFData = textToRTF(originalText)
                        } label: {
                            Label("Revert", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { focusMode.toggle() }
                        } label: {
                            Image(systemName: focusMode
                                  ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(focusMode ? "Exit focus mode" : "Focus mode — hide AI tools")
                    }

                    // RTF editor block
                    VStack(spacing: 0) {
                        FormattingToolbar(fmt: editorFormatState)
                        Divider()
                        RichTextEditor(rtfData: $sourceRTFData, isEditable: true, formatState: editorFormatState)
                            .frame(minHeight: 240)
                            .onAppear { connectDictation() }
                    }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

                    if !focusMode {
                        // Dictation controls
                        dictationControlsView

                        // Split warning
                        if plainTextForAI.count > Self.splitThreshold, onAcceptSplit != nil {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text("Large text (~\(estimatedChunks(for: plainTextForAI)) chunks). For better AI results, consider splitting into multiple sources before running AI.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Split Now…") { splitSheetRTFData = sourceRTFData }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.orange.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.25), lineWidth: 0.5))
                        }

                        Divider()

                        // AI section disclosure header
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { aiExpanded.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "wand.and.sparkles")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                Text("AI Actions")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                if !aiExpanded && !pipelineRuns.isEmpty {
                                    Text("(\(pipelineRuns.count) result\(pipelineRuns.count == 1 ? "" : "s"))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Image(systemName: aiExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)

                        if aiExpanded {
                            // AI actions card
                            VStack(spacing: 0) {
                                // Card header
                                HStack {
                                    Text("AI Actions")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        appState.inspectorDefaultScope = .source
                                        appState.inspectorVisible = true
                                    } label: {
                                        Image(systemName: "slider.horizontal.3")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Manage Before Combining actions")
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(nsColor: .controlBackgroundColor))

                                Divider()

                                // Run preset action row
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Run Preset Action")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .textCase(.uppercase)

                                    if sourcePipelines.isEmpty {
                                        Text("No Before Combining actions yet — tap ⠿ to add one.")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    } else {
                                        HStack(spacing: 8) {
                                            Picker("", selection: $selectedSourcePipelineID) {
                                                Text("Choose an action…").tag(nil as PersistentIdentifier?)
                                                ForEach(sourcePipelines) { p in
                                                    Text(p.name).tag(p.id as PersistentIdentifier?)
                                                }
                                            }
                                            .pickerStyle(.menu)
                                            .labelsHidden()
                                            .frame(maxWidth: .infinity)

                                            if isRunningPipeline {
                                                if let p = pipelineProgress {
                                                    PipelineProgressView(progress: p).transition(.opacity)
                                                } else {
                                                    ProgressView().controlSize(.small)
                                                }
                                                Button("Cancel") {
                                                    runningPipelineTask?.cancel()
                                                    runningPipelineTask = nil
                                                }
                                                .buttonStyle(.bordered)
                                                .controlSize(.small)
                                            } else {
                                                Button("Run") { runSourcePipeline() }
                                                    .buttonStyle(.borderedProminent)
                                                    .controlSize(.small)
                                                    .disabled(selectedSourcePipelineID == nil || plainTextForAI.isEmpty)
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)

                                HStack {
                                    VStack { Divider() }
                                    Text("or")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .fixedSize()
                                    VStack { Divider() }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)

                                // Refine with AI row
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("Refine with AI")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .textCase(.uppercase)
                                        Spacer()
                                        Text("Each prompt builds on the last")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }

                                    HStack(alignment: .top, spacing: 8) {
                                        TextField("Type an instruction…", text: $freeformPromptText, axis: .vertical)
                                            .textFieldStyle(.roundedBorder)
                                            .font(.callout)
                                            .lineLimit(2...4)
                                            .disabled(isRunningFreeform)

                                        VStack(alignment: .leading, spacing: 4) {
                                            if isRunningFreeform {
                                                if let p = freeformProgress, p.chunkCount > 1 {
                                                    PipelineProgressView(progress: p)
                                                } else {
                                                    ProgressView().controlSize(.small)
                                                }
                                                Button("Cancel") {
                                                    runningFreeformTask?.cancel()
                                                    runningFreeformTask = nil
                                                }
                                                .buttonStyle(.bordered)
                                                .controlSize(.small)
                                            } else {
                                                Button("Send") {
                                                    runningFreeformTask = Task { await runFreeformPrompt() }
                                                }
                                                .buttonStyle(.borderedProminent)
                                                .controlSize(.small)
                                                .disabled(freeformPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plainTextForAI.isEmpty)
                                            }
                                        }
                                        .padding(.top, 2)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)

                                HStack {
                                    VStack { Divider() }
                                    Text("or")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .fixedSize()
                                    VStack { Divider() }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)

                                // Translate row
                                HStack(spacing: 8) {
                                    Text("Translate")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .textCase(.uppercase)
                                    Spacer()
                                    if isTranslating {
                                        ProgressView().controlSize(.small)
                                        Text("Translating…").font(.caption).foregroundStyle(.secondary)
                                        Button("Cancel") {
                                            translateTask?.cancel()
                                            translateTask = nil
                                            isTranslating = false
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    } else {
                                        TranslateButton(
                                            helpText: "Translate the captured text using AI"
                                        ) { lang in
                                            translate(to: lang)
                                        }
                                        .disabled(plainTextForAI.isEmpty)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                            }
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2), lineWidth: 1))

                            if !pipelineRuns.isEmpty {
                                VStack(spacing: 8) {
                                    ForEach($pipelineRuns) { $run in
                                        PipelineRunBubble(
                                            run: $run,
                                            onTransfer: {
                                                sourceRTFData = run.resultRTF
                                                run.isTransferred = true
                                            },
                                            onDelete: run.pipelineName == "Refine with AI" && !run.isTransferred ? {
                                                pipelineRuns.removeAll { $0.id == run.id }
                                            } : nil
                                        )
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                    }
                                }
                                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: pipelineRuns.count)
                            }
                        }
                    } // end if !focusMode

                    if let err = errorText {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    runningPipelineTask?.cancel()
                    translateTask?.cancel()
                    stopDictationIfActive()
                    onCancel()
                }
                .buttonStyle(.bordered)

                if let onBack {
                    Button("Back") {
                        runningPipelineTask?.cancel()
                        runningPipelineTask = nil
                        stopDictationIfActive()
                        onBack()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Accept") { accept() }
                    .buttonStyle(.borderedProminent)
                    .disabled(sourceRTFData == nil && plainTextForAI.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Dictation

    private func connectDictation() {
        guard let tv = editorFormatState.textView else { return }
        final class DS { var start: Int? = nil; var len = 0 }
        let s = DS()
        let proxy = TextInsertionProxy()
        proxy.insertAtCursor = { [weak tv] t in tv?.insertText(t, replacementRange: tv?.selectedRange() ?? NSRange()) }
        proxy.startDictation = { [weak tv, s] in s.start = tv?.selectedRange().location; s.len = 0 }
        proxy.updateDictation = { [weak tv, s] t in
            guard let tv, let start = s.start else { return }
            tv.insertText(t, replacementRange: NSRange(location: start, length: s.len))
            s.len = (t as NSString).length
        }
        proxy.endDictation = { [s] in s.start = nil; s.len = 0 }
        dictation.proxy = proxy
    }

    private var dictationControlsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dictation.isActive {
                HStack(spacing: 10) {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.red)
                            .frame(width: geo.size.width * CGFloat(dictation.level))
                            .animation(.linear(duration: 0.08), value: dictation.level)
                    }
                    .frame(height: 6)
                    .background(Color.red.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                    Button("Stop Dictating") { Task { await dictation.stop() } }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .controlSize(.small)
                }
            } else {
                Button {
                    errorText = nil
                    connectDictation()
                    Task {
                        do { try await dictation.start() }
                        catch { errorText = "Dictation failed: \(error.localizedDescription)" }
                    }
                } label: {
                    Label("Dictate", systemImage: "mic.badge.plus").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Dictate text and insert it at the cursor position")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: dictation.isActive)
    }

    private func stopDictationIfActive() {
        guard dictation.isActive else { return }
        dictation.cancel()
    }

    // MARK: - Plain text extraction

    private var plainTextForAI: String {
        guard let data = sourceRTFData,
              let attr = NSAttributedString(rtf: data, documentAttributes: nil)
        else { return "" }
        return attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Accept

    private func accept() {
        stopDictationIfActive()
        let plain = plainTextForAI
        onAccept(plain.isEmpty ? "" : plain, sourceRTFData)
    }

    // MARK: - Pipeline

    private func runSourcePipeline() {
        let textToProcess = plainTextForAI
        guard let pipeline = sourcePipelines.first(where: { $0.id == selectedSourcePipelineID }),
              !textToProcess.isEmpty else { return }
        runningPipelineTask?.cancel()
        pipeline.usageCount += 1
        isRunningPipeline = true
        errorText = nil
        let pipelineName = pipeline.name
        runningPipelineTask = Task { @MainActor in
            do {
                let result = try await DocumentFormattingService().formatToText(
                    sourceText: textToProcess, pipeline: pipeline,
                    onProgress: { [self] p in pipelineProgress = p })
                if !Task.isCancelled {
                    pipelineRuns.append(PipelineRun(pipelineName: pipelineName, result: result, resultRTF: textToRTF(result)))
                }
            } catch {
                if !Task.isCancelled {
                    errorText = "Action failed: \(error.localizedDescription)"
                }
            }
            isRunningPipeline = false
            pipelineProgress = nil
            runningPipelineTask = nil
        }
    }

    private func translate(to language: TranslationLanguage) {
        let source = plainTextForAI
        guard !source.isEmpty else { return }
        isTranslating = true
        errorText = nil
        translateTask = Task { @MainActor in
            do {
                let result = try await DocumentFormattingService()
                    .formatWithPrompt(sourceText: source, systemPrompt: language.promptText)
                if !Task.isCancelled {
                    pipelineRuns.append(PipelineRun(pipelineName: "Translate to \(language.name)", result: result, resultRTF: textToRTF(result)))
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { errorText = "Translation failed: \(error.localizedDescription)" }
            }
            isTranslating = false
            translateTask = nil
        }
    }

    private func runFreeformPrompt() async {
        let prompt = freeformPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentPlain = plainTextForAI
        guard !prompt.isEmpty, !currentPlain.isEmpty else { return }
        isRunningFreeform = true
        freeformProgress = nil
        errorText = nil
        let chainInput = pipelineRuns.last(where: { $0.pipelineName == "Refine with AI" })?.result ?? currentPlain
        let systemPrompt = "You are a helpful assistant editing a text transcript. Follow this instruction exactly and return only the modified text, with no preamble: \(prompt)"
        do {
            let result = try await DocumentFormattingService()
                .formatWithPrompt(sourceText: chainInput, systemPrompt: systemPrompt) { p in
                    freeformProgress = p
                }
            if !result.isEmpty && !Task.isCancelled {
                pipelineRuns.append(PipelineRun(pipelineName: "Refine with AI", result: result, resultRTF: textToRTF(result)))
                freeformPromptText = ""
            }
        } catch is CancellationError {
            // user cancelled — no error shown
        } catch {
            if !Task.isCancelled { errorText = "AI prompt failed: \(error.localizedDescription)" }
        }
        isRunningFreeform = false
        freeformProgress = nil
        runningFreeformTask = nil
    }

    private func estimatedChunks(for text: String) -> Int {
        let chunkSize = ChunkingService.adaptiveChunkSize(for: 400)
        guard chunkSize > 0, !text.isEmpty else { return 1 }
        return max(1, Int(ceil(Double(text.count) / Double(chunkSize))))
    }

    // MARK: - Markdown detection + RTF conversion

    private func looksLikeMarkdown(_ text: String) -> Bool {
        var score = 0
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") || t.hasPrefix("## ") || t.hasPrefix("### ") { score += 2 }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { score += 1 }
            if t.hasPrefix("> ") || t.hasPrefix("```") { score += 1 }
            if MarkdownRenderer.isHRule(t) { score += 1 }
        }
        let boldCount = text.components(separatedBy: "**").count / 2
        let doubleUnderCount = text.components(separatedBy: "__").count / 2
        score += min(boldCount + doubleUnderCount, 4)
        return score >= 2
    }

    // Converts text to RTF via Markdown→HTML→NSAttributedString when markdown
    // is detected; falls back to basic NSAttributedString for plain text.
    private func textToRTF(_ text: String) -> Data? {
        #if canImport(AppKit)
        if looksLikeMarkdown(text) {
            if let data = MarkdownRenderer.toRTF(text) { return data }
        }
        let ns = NSAttributedString(string: text,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        return ns.rtf(from: NSRange(location: 0, length: ns.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        #else
        return nil
        #endif
    }
}

// MARK: - Source split sheet

struct SourceSplitSheet: View {
    let rtfData: Data
    let onConfirm: ([NSAttributedString]) -> Void
    let onCancel: () -> Void

    private let attr: NSAttributedString

    // Split-point state
    @State private var splitAfter: Set<Int> = []
    @State private var wallPartCount: Int = 2
    @State private var maxCharsPerSplit: Int = 0
    @State private var hoveredDivider: Int? = nil

    // Cached results — populated once on appear, rebuilt only when split config changes.
    // Never recomputed during rendering (scroll/hover/click).
    @State private var paragraphsCache: [NSAttributedString] = []
    @State private var partLengthsCache: [Int] = []   // NSString UTF-16 lengths; O(1) per access
    @State private var partCountCache: Int = 0

    init(rtfData: Data,
         onConfirm: @escaping ([NSAttributedString]) -> Void,
         onCancel: @escaping () -> Void) {
        self.rtfData = rtfData
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.attr = (try? NSAttributedString(data: rtfData,
                                              options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                              documentAttributes: nil))
            ?? NSAttributedString(rtf: rtfData, documentAttributes: nil)
            ?? NSAttributedString()
    }

    // O(1) reads from cache — safe to call in body.
    private var isTextWall: Bool { paragraphsCache.count < 3 }
    private var canConfirm: Bool { partCountCache >= 2 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Label("Split Source", systemImage: "scissors")
                    .font(.headline)
                Spacer()
                if maxCharsPerSplit > 0 {
                    HStack(spacing: 4) {
                        Text("Max per part:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Stepper(value: $maxCharsPerSplit, in: 500...100_000, step: 500) {
                            Text(maxCharsPerSplit.formatted())
                                .font(.caption.monospacedDigit())
                                .frame(minWidth: 52, alignment: .trailing)
                        }
                        .controlSize(.small)
                        Button {
                            maxCharsPerSplit = 0
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Button("Set max…") { maxCharsPerSplit = 5_000 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button("Cancel", action: onCancel).buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            if isTextWall { wallSplitterView } else { paragraphSplitterView }

            Divider()

            // Footer: per-part char counts + Confirm
            HStack(spacing: 10) {
                if canConfirm {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            // Use cached lengths — O(1) each, no string traversal.
                            ForEach(0..<partLengthsCache.count, id: \.self) { i in
                                let len  = partLengthsCache[i]
                                let over = maxCharsPerSplit > 0 && len > maxCharsPerSplit
                                HStack(spacing: 3) {
                                    Image(systemName: "\(i + 1).square.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Color.accentColor)
                                    Text("\(len.formatted()) chars")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(over ? Color.orange : Color.secondary)
                                    if over {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text(isTextWall
                         ? "Choose number of parts above"
                         : "Tap the lines between paragraphs to add split points")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Confirm Split") { confirmSplit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 640, height: 540)
        .onAppear {
            // Parse paragraphs once — the only O(total chars) operation in this view.
            paragraphsCache = Self.paragraphsOf(attr)
            rebuildPartCache()
        }
        .onChange(of: splitAfter)      { _, _ in rebuildPartCache() }
        .onChange(of: wallPartCount)   { _, _ in rebuildPartCache() }
        .onChange(of: maxCharsPerSplit) { _, newVal in
            if isTextWall && newVal > 0 {
                wallPartCount = max(2, Int(ceil(Double(attr.length) / Double(newVal))))
            }
            rebuildPartCache()
        }
    }

    // MARK: - Option A: paragraph list with toggle dividers

    private var paragraphSplitterView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Index-based ForEach avoids Array(enumerated()) allocation on every render.
                ForEach(0..<paragraphsCache.count, id: \.self) { i in
                    Text(AttributedString(paragraphsCache[i]))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .textSelection(.enabled)
                        .background(Color(nsColor: .textBackgroundColor))

                    if i < paragraphsCache.count - 1 {
                        toggleDividerRow(after: i)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func toggleDividerRow(after index: Int) -> some View {
        let isActive  = splitAfter.contains(index)
        let isHovered = hoveredDivider == index

        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isActive { splitAfter.remove(index) } else { splitAfter.insert(index) }
            }
        } label: {
            ZStack {
                if isActive {
                    HStack(spacing: 6) {
                        Rectangle().fill(Color.accentColor).frame(height: 1.5)
                        Image(systemName: "scissors")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                        Text("split — tap to remove")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                        Rectangle().fill(Color.accentColor).frame(height: 1.5)
                    }
                    .padding(.horizontal, 12)
                } else if isHovered {
                    HStack(spacing: 4) {
                        Rectangle().fill(Color.accentColor.opacity(0.4)).frame(height: 1)
                        Image(systemName: "plus")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                        Text("tap to split here")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                        Rectangle().fill(Color.accentColor.opacity(0.4)).frame(height: 1)
                    }
                    .padding(.horizontal, 12)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: isActive ? 32 : 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isActive ? Color.accentColor.opacity(0.06) :
            isHovered ? Color.accentColor.opacity(0.03) :
            Color(nsColor: .textBackgroundColor)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                hoveredDivider = hovering ? index : nil
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    // MARK: - Option B: stepper for text walls

    private var wallSplitterView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("This text has no clear paragraph breaks. Choose how many parts to split it into — we'll divide at sentence boundaries.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Stepper(value: $wallPartCount, in: 2...10) {
                    Text("Split into **\(wallPartCount)** parts")
                }

                // Wall preview reads from partLengthsCache; actual previews are pre-built
                // in wallPreviewsCache so the view body stays computation-free.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)

                    ForEach(0..<wallPreviewsCache.count, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Part \(i + 1)")
                                .font(.caption2.bold())
                                .foregroundStyle(Color.accentColor)
                            Text(AttributedString(wallPreviewsCache[i]))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if i < partLengthsCache.count && partLengthsCache[i] > 300 {
                                Text("…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Cache management

    // Pre-built 300-char attributed previews for the wall splitter. Updated with partsCache.
    @State private var wallPreviewsCache: [NSAttributedString] = []

    /// Rebuilds part length and preview caches from the current split configuration.
    /// Called only when split points or counts change — never during rendering.
    private func rebuildPartCache() {
        let builtParts = buildParts()
        partCountCache    = builtParts.count
        partLengthsCache  = builtParts.map { $0.length }
        if isTextWall {
            wallPreviewsCache = builtParts.map { part in
                part.attributedSubstring(from: NSRange(location: 0, length: min(300, part.length)))
            }
        }
    }

    /// Materialises the [NSAttributedString] split result from current config.
    /// Called from rebuildPartCache (on config change) and confirmSplit (on user action).
    private func buildParts() -> [NSAttributedString] {
        if isTextWall { return buildWallParts(count: wallPartCount) }

        // Paragraph mode: combine paragraphsCache using the splitAfter set.
        let paras = paragraphsCache
        let combined = NSMutableAttributedString()
        var result: [NSAttributedString] = []
        for (i, para) in paras.enumerated() {
            if combined.length > 0 { combined.append(NSAttributedString(string: "\n\n")) }
            combined.append(para)
            if splitAfter.contains(i) || i == paras.count - 1 {
                let part = NSAttributedString(attributedString: combined)
                if !part.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(part)
                }
                combined.setAttributedString(NSAttributedString())
            }
        }
        return result
    }

    private func buildWallParts(count: Int) -> [NSAttributedString] {
        guard count >= 2, attr.length > 0 else { return [attr] }
        let ns = attr.string as NSString
        let total = ns.length
        var splitPoints: [Int] = []
        for i in 1..<count {
            let target = (total * i) / count
            var found: Int? = nil
            for j in target..<min(target + 600, total) {
                let c = ns.character(at: j)
                if (c == 0x2E || c == 0x21 || c == 0x3F), j + 1 < total {
                    let n = ns.character(at: j + 1)
                    if n == 0x20 || n == 0x0A || n == 0x0D { found = j + 1; break }
                }
            }
            if found == nil {
                for j in stride(from: target - 1, through: max(target - 600, 0), by: -1) {
                    let c = ns.character(at: j)
                    if (c == 0x2E || c == 0x21 || c == 0x3F), j + 1 < total {
                        let n = ns.character(at: j + 1)
                        if n == 0x20 || n == 0x0A || n == 0x0D { found = j + 1; break }
                    }
                }
            }
            let sp = found ?? target
            if splitPoints.isEmpty || sp > splitPoints.last! { splitPoints.append(sp) }
        }
        var parts: [NSAttributedString] = []
        var start = 0
        for sp in splitPoints {
            let end = min(sp, total)
            if end > start {
                let sub = attr.attributedSubstring(from: NSRange(location: start, length: end - start))
                if !sub.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(sub) }
            }
            start = end
        }
        if start < total {
            let sub = attr.attributedSubstring(from: NSRange(location: start, length: total - start))
            if !sub.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(sub) }
        }
        return parts.isEmpty ? [attr] : parts
    }

    private func confirmSplit() {
        // Materialise the full attributed strings only at the moment of confirmation.
        let result = buildParts().filter {
            !$0.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard result.count >= 2 else { return }
        onConfirm(result)
    }

    // MARK: - Static helpers

    private static func paragraphsOf(_ attr: NSAttributedString) -> [NSAttributedString] {
        var result: [NSAttributedString] = []
        let ns  = attr.string as NSString
        var loc = 0
        while loc < ns.length {
            let r   = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let sub = attr.attributedSubstring(from: r)
            if !sub.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(sub)
            }
            let next = NSMaxRange(r)
            if next <= loc { break }
            loc = next
        }
        return result
    }
}
