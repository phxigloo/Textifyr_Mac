import SwiftUI
import SwiftData
import AppKit
import Combine
import NaturalLanguage
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

    // Source (captured input) and Result (the draft that Accept saves). Source→action→Result.
    @State private var sourceRTFData: Data? = nil
    @State private var resultRTFData: Data? = nil
    @StateObject private var editorFormatState = TextFormatState()   // source editor + dictation
    @StateObject private var resultFormatState = TextFormatState()   // result editor
    @StateObject private var dictation = DictationHolder()

    @State private var selectedSourcePipelineID: PersistentIdentifier? = nil
    @State private var isRunningPipeline = false
    @State private var runningPipelineTask: Task<Void, Never>? = nil
    @State private var pipelineProgress: DocumentFormattingService.Progress? = nil
    @State private var errorText: String? = nil

    @State private var splitSheetRTFData: Data? = nil
    @State private var showActionEditor = false

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
            // Build/edit a Before Combining action over the review step; new actions appear in the
            // "Run Preset Action" picker on dismiss (live @Query). The current transcript is
            // forwarded so the action can be tested against real text (Spec 2).
            .sheet(isPresented: $showActionEditor) {
                ScopedPipelineEditorSheet(scope: .source, sampleText: plainTextForAI)
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
        // Result starts as a copy of the source → "None (keep as captured)" is the default and
        // Accept is valid immediately with no clicks.
        if resultRTFData == nil { resultRTFData = sourceRTFData }
        reviewStepIndex = 1
    }

    // MARK: - Review view

    private var reviewView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

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

                    sourceSection
                    actionSection
                    resultSection

                    if let err = errorText {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }

            ToolColumnFooter {
                Button("Cancel") {
                    runningPipelineTask?.cancel()
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
                    .disabled(resultPlain.isEmpty)
            }
        }
    }

    // MARK: - Source (captured input)

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Captured Source")
                    .font(.subheadline).bold()
                    .foregroundStyle(.secondary)
                if let count = charCount(sourceRTFData) {
                    Text("\(count) chars")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                dictateControl
                Button {
                    sourceRTFData = textToRTF(originalText)
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Restore the originally captured text")
            }

            RichTextEditor(rtfData: $sourceRTFData, isEditable: true, formatState: editorFormatState)
                .frame(minHeight: 130, maxHeight: 260)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
                .onAppear { connectDictation() }

            if dictation.isActive {
                dictationLevelBar
            }

            // Large-text affordance — splits the captured source into multiple sources.
            if plainTextForAI.count > Self.splitThreshold, onAcceptSplit != nil {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                    Text("Large text (~\(estimatedChunks(for: plainTextForAI)) chunks). For better AI results, consider splitting into multiple sources.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Split Now…") { splitSheetRTFData = sourceRTFData }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.25), lineWidth: 0.5))
            }
        }
    }

    // MARK: - Action (source → result)

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Action")
                    .font(.caption2).textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Spacer()
                // Progress and cancellation live in the sheet now.
                TranslateButton(helpText: "Translate the captured text into the result",
                                sourceText: { plainTextForAI },
                                onTranslated: { resultRTFData = textToRTF($0) })
                    .disabled(plainTextForAI.isEmpty || isRunningPipeline)
                Button {
                    showActionEditor = true
                } label: {
                    Label("New or Edit…", systemImage: "slider.horizontal.3").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Create or edit a Before Combining action")
            }

            HStack(spacing: 8) {
                Picker("", selection: $selectedSourcePipelineID) {
                    Text("None (keep as captured)").tag(nil as PersistentIdentifier?)
                    ForEach(sourcePipelines) { p in
                        Text(p.name).tag(p.id as PersistentIdentifier?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(isRunningPipeline)

                if isRunningPipeline {
                    if let p = pipelineProgress {
                        PipelineProgressView(progress: p).transition(.opacity)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("Cancel") {
                        runningPipelineTask?.cancel(); runningPipelineTask = nil
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button(selectedSourcePipelineID == nil ? "Use Captured Text" : "Run") {
                        runSelectedAction()
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(plainTextForAI.isEmpty)
                }
            }

            Text("Actions are reusable recipes built from prompts. The result appears below, where you can edit it before accepting.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    // MARK: - Result (the draft Accept saves)

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Result")
                    .font(.subheadline).bold()
                    .foregroundStyle(.secondary)
                if let count = charCount(resultRTFData) {
                    Text("\(count) chars")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    resultRTFData = textToRTF("")
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(resultPlain.isEmpty)
                .help("Empty the result field")
                Text("Saved when you Accept")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            VStack(spacing: 0) {
                FormattingToolbar(fmt: resultFormatState)
                Divider()
                RichTextEditor(rtfData: $resultRTFData, isEditable: true, formatState: resultFormatState)
                    .frame(minHeight: 200)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
        }
    }

    // MARK: - Dictation UI

    private var dictateControl: some View {
        Group {
            if !dictation.isActive {
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
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dictate text and insert it into the source at the cursor")
            }
        }
    }

    private var dictationLevelBar: some View {
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
                .buttonStyle(.bordered).tint(.red).controlSize(.small)
        }
        .animation(.easeInOut(duration: 0.2), value: dictation.isActive)
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

    /// The Result field's plain text — this is what Accept saves.
    private var resultPlain: String {
        guard let data = resultRTFData,
              let attr = NSAttributedString(rtf: data, documentAttributes: nil)
        else { return "" }
        return attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func charCount(_ data: Data?) -> Int? {
        guard let data, let attr = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
        return attr.string.count
    }

    // MARK: - Accept

    private func accept() {
        stopDictationIfActive()
        onAccept(resultPlain, resultRTFData)
    }

    // MARK: - Action (source → result)

    /// Produces the Result from the Source. "None" copies the captured text through; a selected
    /// action runs on the source and writes its output into Result (replacing it).
    private func runSelectedAction() {
        let input = plainTextForAI
        guard !input.isEmpty else { return }

        guard let pipeline = sourcePipelines.first(where: { $0.id == selectedSourcePipelineID }) else {
            // "None (keep as captured)" — pass the source through unchanged.
            resultRTFData = sourceRTFData
            return
        }

        runningPipelineTask?.cancel()
        pipeline.usageCount += 1
        isRunningPipeline = true
        errorText = nil
        runningPipelineTask = Task { @MainActor in
            do {
                let result = try await DocumentFormattingService().formatToText(
                    sourceText: input, pipeline: pipeline,
                    onProgress: { [self] p in pipelineProgress = p })
                if !Task.isCancelled { resultRTFData = textToRTF(result) }
            } catch is CancellationError {
                // user cancelled — leave the prior result in place
            } catch {
                if !Task.isCancelled { errorText = "Action failed: \(error.localizedDescription)" }
            }
            isRunningPipeline = false
            pipelineProgress = nil
            runningPipelineTask = nil
        }
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
    @AppStorage("textifyr.splitMaxChars") private var lastMaxCharsPerSplit: Int = 5_000
    @State private var hoveredDivider: Int? = nil
    @State private var scrollTarget: Int? = nil
    @State private var suggestedSplits: Set<Int> = []
    @State private var searchText: String = ""
    @State private var searchMatchIndices: [Int] = []
    @State private var searchMatchCursor: Int = 0
    @State private var currentVisiblePart: Int = 0
    // Cached results — populated once on appear, rebuilt only when split config changes.
    // Never recomputed during rendering (scroll/hover/click).
    @State private var paragraphsCache: [NSAttributedString] = []
    @State private var partLengthsCache: [Int] = []   // NSString UTF-16 lengths; O(1) per access
    @State private var partCountCache: Int = 0
    @State private var paragraphPartIndices: [Int] = []  // part index per paragraph; rebuilt with cache

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

    private func partIndex(for paragraphIndex: Int) -> Int {
        let sorted = splitAfter.sorted()
        for (i, sp) in sorted.enumerated() {
            if paragraphIndex <= sp { return i }
        }
        return sorted.count
    }

    private func partNumberStartingAfter(_ index: Int) -> Int {
        splitAfter.filter { $0 <= index }.count + 1
    }

    private static let partColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal
    ]

    private func color(forPart part: Int) -> Color {
        Self.partColors[part % Self.partColors.count]
    }

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
                    Button("Set max…") { maxCharsPerSplit = lastMaxCharsPerSplit }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button("Cancel", action: onCancel).buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            if !isTextWall && !paragraphsCache.isEmpty {
                searchBarView
                Divider()
            }

            if isTextWall { wallSplitterView } else { paragraphSplitterView }

            Divider()

            // Footer: part navigator menu + Confirm
            HStack(spacing: 10) {
                if canConfirm {
                    let anyOver = maxCharsPerSplit > 0 && partLengthsCache.contains { $0 > maxCharsPerSplit }
                    Menu {
                        ForEach(0..<partLengthsCache.count, id: \.self) { i in
                            Button {
                                scrollTarget = partStartParagraph(i)
                            } label: {
                                let len  = partLengthsCache[i]
                                let over = maxCharsPerSplit > 0 && len > maxCharsPerSplit
                                Text("Part \(i + 1): \(len.formatted()) chars\(over ? " ⚠" : "")")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "list.number").font(.caption2)
                            Text("\(partCountCache) part\(partCountCache == 1 ? "" : "s")")
                                .font(.caption2.monospacedDigit())
                        }
                        .foregroundStyle(anyOver ? Color.orange : Color.accentColor)
                    }
                    .help("Jump to a part in the list")
                } else {
                    Text(isTextWall
                         ? "Choose number of parts above"
                         : "Tap the lines between paragraphs to add split points")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if !isTextWall && !suggestedSplits.isEmpty {
                    Button("Accept Suggested") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            splitAfter.formUnion(suggestedSplits)
                            suggestedSplits.removeAll()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                if !isTextWall && paragraphsCache.count >= 2 && splitAfter.count < paragraphsCache.count - 1 {
                    Button("Accept All Splits") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            splitAfter = Set(0..<(paragraphsCache.count - 1))
                        }
                    }
                    .buttonStyle(.bordered)
                }
                Button("Confirm Split") { confirmSplit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 720, height: 560)
        .onAppear {
            // Parse paragraphs once. Paragraphs over 1,500 chars are sub-divided
            // at sentence boundaries so splits can be placed within large blocks.
            paragraphsCache = Self.paragraphsOf(attr, sentenceThreshold: 1_500)
            rebuildPartCache()
            if !isTextWall && maxCharsPerSplit > 0 {
                suggestedSplits = computeSuggestedSplits(maxCharsPerSplit)
            }
        }
        .onChange(of: splitAfter) { _, new in
            rebuildPartCache()
            suggestedSplits.subtract(new)
        }
        .onChange(of: wallPartCount)   { _, _ in rebuildPartCache() }
        .onChange(of: maxCharsPerSplit) { _, newVal in
            if newVal > 0 { lastMaxCharsPerSplit = newVal }
            if isTextWall && newVal > 0 {
                wallPartCount = max(2, Int(ceil(Double(attr.length) / Double(newVal))))
            }
            rebuildPartCache()
            if !isTextWall {
                suggestedSplits = newVal > 0
                    ? computeSuggestedSplits(newVal).subtracting(splitAfter)
                    : []
            }
        }
        .onChange(of: searchText) { _, newText in
            updateSearch(query: newText)
        }
    }

    // MARK: - Option A: two-panel layout (sidebar + paragraph list)

    private var paragraphSplitterView: some View {
        HStack(spacing: 0) {
            segmentSidebar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<paragraphsCache.count, id: \.self) { i in
                            Text(AttributedString(paragraphsCache[i]))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .textSelection(.enabled)
                                .background(
                                    (!searchMatchIndices.isEmpty
                                        && searchMatchCursor < searchMatchIndices.count
                                        && searchMatchIndices[searchMatchCursor] == i)
                                        ? Color.yellow.opacity(0.35)
                                        : (partCountCache >= 2 && i < paragraphPartIndices.count)
                                            ? color(forPart: paragraphPartIndices[i]).opacity(0.10)
                                            : Color(nsColor: .textBackgroundColor)
                                )
                                .id(i)

                            if i < paragraphsCache.count - 1 {
                                toggleDividerRow(after: i)
                            }
                        }
                    }
                }
                .onScrollGeometryChange(for: Int.self) { geo in
                    let fraction = geo.contentOffset.y / max(1, geo.contentSize.height)
                    let paraIdx = min(
                        Int(fraction * CGFloat(max(1, paragraphsCache.count))),
                        max(0, paragraphsCache.count - 1)
                    )
                    return partIndex(for: paraIdx)
                } action: { _, newPart in
                    currentVisiblePart = newPart
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: scrollTarget) { _, target in
                    guard let t = target else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        if t >= 0 {
                            proxy.scrollTo(t, anchor: .top)
                        } else {
                            // Negative encoding: divider after paragraph (-t - 1)
                            proxy.scrollTo("d\(-t - 1)", anchor: .top)
                        }
                    }
                    scrollTarget = nil
                }
            }
        }
    }

    // MARK: - Segment sidebar

    private var segmentSidebar: some View {
        let activePart = currentVisiblePart
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<partCountCache, id: \.self) { i in
                        segmentRow(i, isActive: activePart == i)
                        if i < partCountCache - 1 {
                            Divider()
                                .padding(.horizontal, 10)
                        }
                    }
                    if partCountCache == 0 {
                        Text("Add split points\nto see segments")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: activePart) { _, part in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(part, anchor: .center)
                }
            }
        }
        .frame(width: 148)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func segmentRow(_ i: Int, isActive: Bool) -> some View {
        let len    = i < partLengthsCache.count ? partLengthsCache[i] : 0
        let isOver = maxCharsPerSplit > 0 && len > maxCharsPerSplit

        Button {
            if i == 0 {
                scrollTarget = 0
            } else {
                let sorted = splitAfter.sorted()
                if i - 1 < sorted.count {
                    scrollTarget = -(sorted[i - 1] + 1)  // divider encoding
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(forPart: i))
                        .frame(width: 8, height: 8)
                    Text("Part \(i + 1)")
                        .font(.caption.bold())
                        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                }
                HStack(spacing: 4) {
                    Text(len.formatted())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isOver ? Color.orange : Color.secondary)
                    Text("chars")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if isOver {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isActive ? Color.accentColor.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOver ? "Part \(i + 1) has \(len.formatted()) chars — exceeds the \(maxCharsPerSplit.formatted())-char limit" : "")
        .id(i)
    }

    @ViewBuilder
    private func toggleDividerRow(after index: Int) -> some View {
        let isActive    = splitAfter.contains(index)
        let isSuggested = !isActive && suggestedSplits.contains(index)
        let isHovered   = hoveredDivider == index

        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isActive {
                    splitAfter.remove(index)
                } else {
                    splitAfter.insert(index)
                    suggestedSplits.remove(index)
                }
            }
        } label: {
            ZStack {
                if isActive {
                    HStack(spacing: 6) {
                        Rectangle().fill(Color.accentColor).frame(height: 1.5)
                        Image(systemName: "scissors")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                        Text("Part \(partNumberStartingAfter(index)) begins — tap to remove")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                        Rectangle().fill(Color.accentColor).frame(height: 1.5)
                    }
                    .padding(.horizontal, 12)
                } else if isSuggested && isHovered {
                    HStack(spacing: 6) {
                        Rectangle().fill(Color.orange.opacity(0.7)).frame(height: 1.5)
                        Image(systemName: "scissors")
                            .font(.caption2)
                            .foregroundStyle(Color.orange)
                        Text("suggested — tap to confirm")
                            .font(.caption2)
                            .foregroundStyle(Color.orange)
                        Rectangle().fill(Color.orange.opacity(0.7)).frame(height: 1.5)
                    }
                    .padding(.horizontal, 12)
                } else if isSuggested {
                    HStack(spacing: 6) {
                        Rectangle().fill(Color.orange.opacity(0.45)).frame(height: 1)
                        Image(systemName: "lightbulb.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.orange.opacity(0.8))
                        Text("suggested split")
                            .font(.caption2)
                            .foregroundStyle(Color.orange.opacity(0.8))
                        Rectangle().fill(Color.orange.opacity(0.45)).frame(height: 1)
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
            .frame(height: isActive ? 32 : (isSuggested ? 27 : 22))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isActive    ? Color.accentColor.opacity(0.06) :
            isSuggested ? Color.orange.opacity(0.05) :
            isHovered   ? Color.accentColor.opacity(0.03) :
            Color(nsColor: .textBackgroundColor)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                hoveredDivider = hovering ? index : nil
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .animation(.easeInOut(duration: 0.15), value: isSuggested)
        .id("d\(index)")
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
        } else {
            // O(n + k) pass: assign each paragraph its part index.
            let sorted = splitAfter.sorted()
            var indices = [Int](repeating: 0, count: paragraphsCache.count)
            var part = 0
            var splitIdx = 0
            for i in 0..<paragraphsCache.count {
                while splitIdx < sorted.count && sorted[splitIdx] < i {
                    part += 1
                    splitIdx += 1
                }
                indices[i] = part
            }
            paragraphPartIndices = indices
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

    /// Returns the paragraph index that starts part `partIndex` (0-based).
    /// Used by the navigation menu to scroll the list to the beginning of a part.
    private func partStartParagraph(_ partIndex: Int) -> Int {
        guard !isTextWall, partIndex > 0 else { return 0 }
        let sorted = splitAfter.sorted()
        guard partIndex - 1 < sorted.count else { return 0 }
        return sorted[partIndex - 1] + 1
    }

    // MARK: - Smart split suggestion

    /// Greedy pass: accumulate paragraph lengths until exceeding targetChars, then split.
    /// Produces the minimum set of paragraph-boundary indices that keeps every part ≤ target.
    private func computeSuggestedSplits(_ targetChars: Int) -> Set<Int> {
        guard targetChars > 0, paragraphsCache.count >= 2 else { return [] }
        var result = Set<Int>()
        var accumulated = 0
        for (i, para) in paragraphsCache.enumerated() {
            let paraLen = para.length
            // Split before this sentence if adding it would exceed the limit.
            // This keeps the current part at or under the limit rather than over.
            // Exception: if accumulated is 0 the sentence is unavoidably oversized;
            // include it alone and let the warning icon flag it.
            if accumulated > 0 && accumulated + paraLen > targetChars {
                result.insert(i - 1)
                accumulated = 0
            }
            accumulated += paraLen
        }
        return result
    }

    // MARK: - Search bar

    private var searchBarView: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search paragraphs…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .onSubmit { jumpToNextMatch() }
            if !searchMatchIndices.isEmpty {
                Text("\(searchMatchCursor + 1) / \(searchMatchIndices.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(action: jumpToNextMatch) {
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(searchMatchIndices.count <= 1)
                .help("Next match")
            }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func updateSearch(query: String) {
        let q = query.lowercased()
        guard !q.isEmpty else {
            searchMatchIndices = []
            searchMatchCursor  = 0
            return
        }
        searchMatchIndices = paragraphsCache.indices.filter {
            paragraphsCache[$0].string.lowercased().contains(q)
        }
        searchMatchCursor = 0
        if let first = searchMatchIndices.first { scrollTarget = first }
    }

    private func jumpToNextMatch() {
        guard !searchMatchIndices.isEmpty else { return }
        searchMatchCursor = (searchMatchCursor + 1) % searchMatchIndices.count
        scrollTarget = searchMatchIndices[searchMatchCursor]
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

    // Splits an attributed string into individual sentences using NLTokenizer,
    // which correctly handles abbreviations, decimals, and ellipsis.
    private static func sentencesOf(_ attr: NSAttributedString) -> [NSAttributedString] {
        let text = attr.string
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [NSAttributedString] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let nsRange = NSRange(range, in: text)
            let sub = attr.attributedSubstring(from: nsRange)
            if !sub.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(sub)
            }
            return true
        }
        return result.isEmpty ? [attr] : result
    }

    // Parses an attributed string into paragraphs. Any paragraph that exceeds
    // sentenceThreshold chars is further divided into individual sentences so the
    // user can place split points at sentence granularity, not just paragraph boundaries.
    private static func paragraphsOf(_ attr: NSAttributedString,
                                     sentenceThreshold: Int = 1_500) -> [NSAttributedString] {
        var result: [NSAttributedString] = []
        let ns  = attr.string as NSString
        var loc = 0
        while loc < ns.length {
            let r   = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let sub = attr.attributedSubstring(from: r)
            if !sub.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if sub.length > sentenceThreshold {
                    result.append(contentsOf: sentencesOf(sub))
                } else {
                    result.append(sub)
                }
            }
            let next = NSMaxRange(r)
            if next <= loc { break }
            loc = next
        }
        return result
    }
}
