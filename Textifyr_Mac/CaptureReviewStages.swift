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

// MARK: - Pipeline run record

struct PipelineRun: Identifiable {
    let id = UUID()
    let pipelineName: String
    let result: String
    var isTransferred = false
}

struct PipelineRunBubble: View {
    @Binding var run: PipelineRun
    let onTransfer: () -> Void

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
                }
            }

            Text(run.result)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .frame(maxHeight: 120)
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

// MARK: - Shared wizard stages 2 & 3

/// Stages 2 (Refine Transcript) and 3 (Final Edit) shared across all input wizards.
/// The outer wizard owns the header/step-indicator; this view owns only the body content.
/// - `reviewStepIndex`: updated by this view as the user moves between process (1) and polish (2).
/// - `onBack`: called when the user taps Back on the process step; nil in edit-mode contexts.
/// - `onCancel`: outer wizard cleans up any in-progress capture and dismisses.
/// - `onAccept`: outer wizard receives the final text, saves it to the session, and dismisses.
struct CaptureReviewStages: View {
    let originalText: String
    let isEditMode: Bool
    let showAutoStoppedBanner: Bool
    @Binding var reviewStepIndex: Int
    var onBack: (() -> Void)?
    let onCancel: () -> Void
    let onAccept: (String) -> Void

    @Query(filter: #Predicate<FormattingPipeline> { $0.scopeRawValue == "source" },
           sort: \FormattingPipeline.name) private var sourcePipelines: [FormattingPipeline]

    @EnvironmentObject private var appState: AppState

    private enum Step { case process, polish }
    @State private var step: Step = .process
    @State private var stepForward = true

    @State private var currentText: String
    @State private var finalText: String
    @State private var selectedSourcePipelineID: PersistentIdentifier? = nil
    @State private var pipelineRuns: [PipelineRun] = []
    @State private var isRunningPipeline = false
    @State private var runningPipelineTask: Task<Void, Never>? = nil
    @State private var pipelineProgress: DocumentFormattingService.Progress? = nil
    @State private var errorText: String? = nil

    @StateObject private var processInsertionProxy = TextInsertionProxy()
    @StateObject private var insertionProxy = TextInsertionProxy()
    @StateObject private var dictation = DictationHolder()

    init(
        originalText: String,
        initialText: String,
        isEditMode: Bool,
        showAutoStoppedBanner: Bool = false,
        reviewStepIndex: Binding<Int>,
        onBack: (() -> Void)? = nil,
        onCancel: @escaping () -> Void,
        onAccept: @escaping (String) -> Void
    ) {
        self.originalText = originalText
        self.isEditMode = isEditMode
        self.showAutoStoppedBanner = showAutoStoppedBanner
        _reviewStepIndex = reviewStepIndex
        self.onBack = onBack
        self.onCancel = onCancel
        self.onAccept = onAccept
        _currentText = State(initialValue: initialText)
        _finalText = State(initialValue: initialText)
    }

    var body: some View {
        ZStack {
            switch step {
            case .process: processView.transition(stepTransition)
            case .polish:  polishView.transition(stepTransition)
            }
        }
        .clipped()
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: stepForward ? .trailing : .leading).combined(with: .opacity),
            removal:   .move(edge: stepForward ? .leading  : .trailing).combined(with: .opacity)
        )
    }

    // MARK: - Step 2: Process

    private var processView: some View {
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

                    HStack(alignment: .firstTextBaseline) {
                        Text("Transcript")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(currentText.count.formatted()) chars")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Button { currentText = originalText } label: {
                            Label("Revert to Original", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(currentText == originalText
                            ? AnyShapeStyle(Color.secondary)
                            : AnyShapeStyle(Color.accentColor))
                        .disabled(currentText == originalText)
                        .animation(.easeInOut(duration: 0.15), value: currentText == originalText)
                    }

                    DictationAwareTextEditor(text: $currentText, proxy: processInsertionProxy)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .frame(minHeight: 160, maxHeight: 200)

                    dictationControls(for: .process)

                    Divider()

                    HStack(spacing: 8) {
                        if sourcePipelines.isEmpty {
                            Text("No Refine Transcript pipelines yet.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            Picker("Run Pipeline", selection: $selectedSourcePipelineID) {
                                Text("Choose a pipeline…").tag(nil as PersistentIdentifier?)
                                ForEach(sourcePipelines) { p in
                                    Text(p.name).tag(p.id as PersistentIdentifier?)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 240)
                            .labelsHidden()

                            Button("Run") { runSourcePipeline() }
                                .buttonStyle(.bordered)
                                .disabled(selectedSourcePipelineID == nil || isRunningPipeline || currentText.isEmpty)

                            if let p = pipelineProgress {
                                PipelineProgressView(progress: p).transition(.opacity)
                            } else if isRunningPipeline {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Starting…").font(.caption).foregroundStyle(.secondary)
                                }.transition(.opacity)
                            }
                        }

                        Spacer()

                        Button { appState.inspectorVisible = true } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .buttonStyle(.borderless)
                        .help("Manage pipelines")
                    }

                    if !pipelineRuns.isEmpty {
                        VStack(spacing: 8) {
                            ForEach($pipelineRuns) { $run in
                                PipelineRunBubble(run: $run) {
                                    currentText = run.result
                                    run.isTransferred = true
                                }
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: pipelineRuns.count)
                    }

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

                Button("Continue") {
                    stopDictationIfActive()
                    finalText = currentText
                    reviewStepIndex = 2
                    stepForward = true
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { step = .polish }
                }
                .buttonStyle(.borderedProminent)
                .disabled(currentText.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Step 3: Final Edit

    private var polishView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    HStack(alignment: .firstTextBaseline) {
                        Text("Final Edit")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(finalText.count.formatted()) chars")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }

                    DictationAwareTextEditor(text: $finalText, proxy: insertionProxy)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .frame(minHeight: 240)

                    dictationControls(for: .polish)

                    if let err = errorText {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    stopDictationIfActive()
                    onCancel()
                }
                .buttonStyle(.bordered)

                Button("Back") {
                    stopDictationIfActive()
                    reviewStepIndex = 1
                    stepForward = false
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { step = .process }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Accept") {
                    stopDictationIfActive()
                    onAccept(finalText)
                }
                .buttonStyle(.borderedProminent)
                .disabled(finalText.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Dictation

    private func dictationControls(for step: Step) -> some View {
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
                Button { startDictation(for: step) } label: {
                    Label("Dictate", systemImage: "mic.badge.plus").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Dictate text and insert it at the cursor position")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: dictation.isActive)
    }

    private func startDictation(for step: Step) {
        errorText = nil
        dictation.proxy = step == .process ? processInsertionProxy : insertionProxy
        Task {
            do { try await dictation.start() }
            catch { errorText = "Dictation failed: \(error.localizedDescription)" }
        }
    }

    private func stopDictationIfActive() {
        guard dictation.isActive else { return }
        dictation.cancel()
    }

    // MARK: - Pipeline

    private func runSourcePipeline() {
        guard let pipeline = sourcePipelines.first(where: { $0.id == selectedSourcePipelineID }),
              !currentText.isEmpty else { return }
        runningPipelineTask?.cancel()
        isRunningPipeline = true
        errorText = nil
        let textToProcess = currentText
        let pipelineName = pipeline.name
        runningPipelineTask = Task { @MainActor in
            do {
                let result = try await DocumentFormattingService().formatToText(
                    sourceText: textToProcess, pipeline: pipeline,
                    onProgress: { [self] p in pipelineProgress = p })
                if !Task.isCancelled {
                    pipelineRuns.append(PipelineRun(pipelineName: pipelineName, result: result))
                }
            } catch {
                if !Task.isCancelled {
                    errorText = "Pipeline failed: \(error.localizedDescription)"
                }
            }
            isRunningPipeline = false
            pipelineProgress = nil
            runningPipelineTask = nil
        }
    }
}
