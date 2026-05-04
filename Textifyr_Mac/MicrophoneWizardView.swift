import SwiftUI
import SwiftData
import AppKit
import Combine
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

// openWindow is injected from the environment; wizard steps use it to open
// the Prompt Builder without a sheet/dismiss dependency.


// MARK: - Dictation support

private final class TextInsertionProxy: ObservableObject {
    var insertAtCursor: ((String) -> Void)?
    var startDictation: (() -> Void)?
    var updateDictation: ((String) -> Void)?
    var endDictation: (() -> Void)?
}

/// Manages a SpeechCaptureService for inline dictation.
/// Streams finalised segments in real time to an onFinalSegment callback;
/// shows the in-progress volatile text via volatilePreview.
@MainActor
private final class DictationHolder: ObservableObject {
    let service = SpeechCaptureService()
    @Published var isActive = false
    @Published var level: Float = 0

    // Set before calling start() so the holder can push text into the right editor.
    var proxy: TextInsertionProxy?

    private var levelTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var volatileTask: Task<Void, Never>?

    func start() async throws {
        let streams = try await service.startCapture()
        isActive = true
        proxy?.startDictation?()   // record cursor position in the text view

        levelTask = Task { [weak self] in
            for await l in streams.levels { self?.level = l }
        }

        // Use volatile updates for real-time word-by-word insertion.
        // SpeechTranscriber only emits isFinal=true after finalizeAndFinish, so
        // we drive the editor with volatile text and reset tracking on each final.
        volatileTask = Task { [weak self] in
            for await text in streams.volatileText {
                guard !text.isEmpty else { continue }
                self?.proxy?.updateDictation?(text)
            }
            self?.proxy?.endDictation?()
        }
        finalTask = Task { [weak self] in
            for await _ in streams.finalSegments {
                // Volatile text for this utterance is now permanent; start fresh.
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
private struct DictationAwareTextEditor: NSViewRepresentable {
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
        private var dictationStart: Int? = nil        // cursor location when dictation began
        private var dictationInsertedLength: Int = 0  // UTF-16 length of last volatile insertion

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

            // Replace the previous volatile insertion with the updated text.
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

private struct PipelineRun: Identifiable {
    let id = UUID()
    let pipelineName: String
    let result: String
    var isTransferred = false
}

// MARK: - Main view

struct MicrophoneWizardView: View {
    @ObservedObject private var captureVM: InputCaptureViewModel
    private let initialSession: SourceSession?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    @Query(filter: #Predicate<FormattingPipeline> { $0.scopeRawValue == "postCapture" },
           sort: \FormattingPipeline.name) private var postCapturePipelines: [FormattingPipeline]
    @Query(filter: #Predicate<FormattingPipeline> { $0.scopeRawValue == "source" },
           sort: \FormattingPipeline.name) private var sourcePipelines: [FormattingPipeline]

    private enum WizardStep { case acquire, process, polish }
    @State private var wizardStep: WizardStep = .acquire
    @State private var stepForward = true

    // Acquire
    @State private var selectedPostCapturePipelineID: PersistentIdentifier? = nil
    @State private var isRunningPostCapture = false
    @State private var postCaptureTask: Task<Void, Never>? = nil
    @State private var postCaptureError: String? = nil

    // Session & text
    @State private var capturedSession: SourceSession? = nil
    @State private var originalText: String = ""
    @State private var currentText: String = ""

    // Process
    @State private var selectedSourcePipelineID: PersistentIdentifier? = nil
    @State private var pipelineRuns: [PipelineRun] = []
    @State private var isRunningPipeline = false
    @State private var runningPipelineTask: Task<Void, Never>? = nil

    // Polish / Final Edit
    @State private var finalText: String = ""
    @State private var errorText: String? = nil

    // Pipeline editor sheets
    @State private var showingQuickCleanPipelines = false
    @State private var showingSessionPolishPipelines = false

    @StateObject private var processInsertionProxy = TextInsertionProxy()
    @StateObject private var insertionProxy = TextInsertionProxy()
    @StateObject private var dictation = DictationHolder()

    private var isEditMode: Bool { initialSession != nil }
    private static let postCapturePipelineKey = "defaultPostCapturePipelineName"

    init(captureVM: InputCaptureViewModel, initialSession: SourceSession? = nil) {
        self._captureVM = ObservedObject(wrappedValue: captureVM)
        self.initialSession = initialSession
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepContent
        }
        .frame(width: 600)
        .onAppear {
            restorePostCapturePipeline()
            if let session = initialSession {
                capturedSession = session
                originalText = session.rawText
                currentText = session.rawText
                finalText = session.rawText
                wizardStep = .process
            }
        }
        .onChange(of: captureVM.phase) { _, phase in handlePhaseChange(phase) }
        .onChange(of: postCapturePipelines) { _, pipelines in
            // @Query results may not be populated on onAppear — restore here when they arrive.
            guard selectedPostCapturePipelineID == nil,
                  let name = UserDefaults.standard.string(forKey: Self.postCapturePipelineKey)
            else { return }
            selectedPostCapturePipelineID = pipelines.first { $0.name == name }?.id
        }
        .onChange(of: selectedPostCapturePipelineID) { _, id in
            if let id, let p = postCapturePipelines.first(where: { $0.id == id }) {
                UserDefaults.standard.set(p.name, forKey: Self.postCapturePipelineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.postCapturePipelineKey)
            }
        }
        .sheet(isPresented: $showingQuickCleanPipelines) {
            ScopedPipelineEditorSheet(scope: .postCapture)
        }
        .sheet(isPresented: $showingSessionPolishPipelines) {
            ScopedPipelineEditorSheet(scope: .source)
        }
    }

    private func restorePostCapturePipeline() {
        guard let name = UserDefaults.standard.string(forKey: Self.postCapturePipelineKey) else { return }
        selectedPostCapturePipelineID = postCapturePipelines.first { $0.name == name }?.id
    }

    // MARK: - Header
    // Single Cancel is in the bottom bar of each step — not here.

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isEditMode ? "pencil.and.list.clipboard" : "mic.fill")
                .foregroundStyle(.tint)
            Text(isEditMode ? "Edit Recording" : "New Recording")
                .font(.title2).bold()
            Spacer()
            stepIndicator
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(stepIndex >= i ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: stepIndex == i ? 10 : 7, height: stepIndex == i ? 10 : 7)
                    .animation(.easeInOut(duration: 0.2), value: wizardStep)
                if i < 2 {
                    Rectangle()
                        .fill(stepIndex > i ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 32, height: 2)
                }
            }
        }
    }

    private var stepIndex: Int {
        switch wizardStep {
        case .acquire: return 0
        case .process: return 1
        case .polish:  return 2
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: stepForward ? .trailing : .leading).combined(with: .opacity),
            removal:   .move(edge: stepForward ? .leading  : .trailing).combined(with: .opacity)
        )
    }

    // MARK: - Step dispatch

    @ViewBuilder
    private var stepContent: some View {
        ZStack {
            switch wizardStep {
            case .acquire: acquireStep.transition(stepTransition)
            case .process: processStep.transition(stepTransition)
            case .polish:  polishStep.transition(stepTransition)
            }
        }
        .clipped()
    }

    // MARK: - Step 1: Acquire

    private var acquireStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Level meter
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(captureVM.audioLevel))
                            .animation(.linear(duration: 0.1), value: captureVM.audioLevel)
                    }
                    .frame(height: 8)
                    .background(Color.accentColor.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    // Duration counter
                    Text(formattedDuration)
                        .font(.system(.title, design: .monospaced))
                        .foregroundStyle(captureVM.phase == .recording ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    // Recording limit warning — appears 60 s before auto-stop
                    if captureVM.phase == .recording {
                        let remaining = Int(AppConstants.maxLiveRecordingSeconds - captureVM.recordingDuration)
                        if remaining <= Int(AppConstants.liveRecordingWarnSeconds) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text("Auto-stops in \(max(0, remaining))s — 2-hour limit")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .transition(.opacity)
                        }
                    }

                    // Settings card — grouped controls
                    VStack(spacing: 0) {
                        Toggle("Identify Speakers", isOn: $captureVM.diarizationEnabled)
                            .disabled(captureVM.phase != .idle)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)

                        if !postCapturePipelines.isEmpty {
                            Divider().padding(.leading, 12)
                            LabeledContent("Auto Cleanup") {
                                Picker("", selection: $selectedPostCapturePipelineID) {
                                    Text("None").tag(nil as PersistentIdentifier?)
                                    ForEach(postCapturePipelines) { p in
                                        Text(p.name).tag(p.id as PersistentIdentifier?)
                                    }
                                }
                                .pickerStyle(.menu)
                                .disabled(captureVM.phase != .idle)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                        Divider().padding(.leading, 12)
                        HStack {
                            Spacer()
                            Button {
                                showingQuickCleanPipelines = true
                            } label: {
                                Label("Manage Auto Cleanup Pipelines…", systemImage: "slider.horizontal.3")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                    }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

                    // Inline speaker identification
                    if captureVM.phase == .identifySpeakers {
                        speakerIDContent
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Post-capture pipeline progress
                    if isRunningPostCapture {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Running post capture pipeline…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    }

                    // Transcription/diarization progress
                    if [.transcribing, .downloadingModels, .diarizing, .saving].contains(captureVM.phase) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                if captureVM.transcriptionFraction == nil {
                                    ProgressView().controlSize(.small)
                                }
                                Text(acquireProgressLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let fraction = captureVM.transcriptionFraction {
                                ProgressView(value: fraction)
                                    .progressViewStyle(.linear)
                                    .animation(.linear(duration: 0.25), value: fraction)
                            }
                            if let chunk = captureVM.chunkProgress {
                                Text("Minutes \(chunk.minuteStart)–\(chunk.minuteEnd) of \(chunk.totalMinutes)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .transition(.opacity)
                    }

                    if let err = postCaptureError {
                        Text(err).font(.caption).foregroundStyle(.red)
                            .transition(.opacity)
                    }
                    if case .failed(let msg) = captureVM.phase {
                        Text(msg).font(.caption).foregroundStyle(.red)
                            .transition(.opacity)
                    }
                }
                .padding(20)
                .animation(.spring(response: 0.35, dampingFraction: 0.9), value: captureVM.phase == .identifySpeakers)
                .animation(.easeInOut(duration: 0.2), value: isRunningPostCapture)
                .animation(.easeInOut(duration: 0.2), value: postCaptureError)
            }

            Divider()

            // Bottom bar — single Cancel on the left, primary action on the right
            HStack {
                Button("Cancel") { cancel() }.buttonStyle(.bordered)
                if captureVM.phase == .identifySpeakers {
                    Button("Skip") { captureVM.skipSpeakerRename() }.buttonStyle(.bordered)
                }
                Spacer()
                acquireActionButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private var acquireActionButton: some View {
        switch captureVM.phase {
        case .idle:
            Button("Start Recording") {
                Task { await captureVM.startMicRecording() }
            }
            .buttonStyle(.borderedProminent)

        case .recording:
            Button("Stop Recording") {
                captureVM.stopMicRecording()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

        case .identifySpeakers:
            Button("Confirm Speakers") { captureVM.confirmSpeakers() }
                .buttonStyle(.borderedProminent)

        default:
            Button("Processing…") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        }
    }

    private var speakerIDContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Name Speakers").font(.subheadline).bold()
                Text("Optionally rename each speaker. Leave blank to keep the default label.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(captureVM.detectedSpeakers, id: \.self) { speaker in
                    HStack {
                        Text(speaker)
                            .font(.body.bold())
                            .frame(width: 80, alignment: .leading)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                        TextField("Optional name", text: Binding(
                            get: { captureVM.speakerNames[speaker] ?? "" },
                            set: { captureVM.speakerNames[speaker] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }

            if !captureVM.mergedDiarizedText.isEmpty {
                GroupBox("Preview") {
                    ScrollView {
                        Text(String(captureVM.mergedDiarizedText.prefix(400)))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 64)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Step 2: Process

    private var processStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    // Auto-stop notice
                    if captureVM.recordingAutoStopped {
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

                    // Transcript editor — label row with Revert on the trailing side
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

                    dictationControlsForStep(.process)

                    // Refine Transcript pipeline section — always shown so Manage is always reachable
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

                            if isRunningPipeline {
                                ProgressView().controlSize(.small)
                            }
                        }

                        Spacer()

                        Button { showingSessionPolishPipelines = true } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .buttonStyle(.borderless)
                        .help("Manage Refine Transcript pipelines")
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
                Button("Cancel") { cancel() }.buttonStyle(.bordered)
                if !isEditMode {
                    Button("Back") { backFromProcess() }.buttonStyle(.bordered)
                }
                Spacer()
                Button("Continue") {
                    stopDictationIfActive()
                    finalText = currentText
                    stepForward = true
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { wizardStep = .polish }
                }
                .buttonStyle(.borderedProminent)
                .disabled(currentText.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Step 3: Final Edit

    private var polishStep: some View {
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

                    dictationControlsForStep(.polish)

                    if let err = errorText {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button("Cancel") { cancel() }.buttonStyle(.bordered)
                Button("Back") {
                    stopDictationIfActive()
                    stepForward = false
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { wizardStep = .process }
                }.buttonStyle(.bordered)
                Spacer()
                Button("Accept") { accept() }
                    .buttonStyle(.borderedProminent)
                    .disabled(finalText.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Dictation controls

    private func dictationControlsForStep(_ step: WizardStep) -> some View {
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

                    Button("Stop Dictating") { Task { await stopDictation() } }
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

    // MARK: - Dictation

    private func startDictation(for step: WizardStep) {
        errorText = nil
        dictation.proxy = step == .process ? processInsertionProxy : insertionProxy
        Task {
            do { try await dictation.start() }
            catch { errorText = "Dictation failed: \(error.localizedDescription)" }
        }
    }

    private func stopDictation() async { await dictation.stop() }

    private func stopDictationIfActive() {
        guard dictation.isActive else { return }
        dictation.cancel()
    }

    // MARK: - Phase handling

    private func handlePhaseChange(_ phase: CapturePhase) {
        guard phase == .done else { return }
        guard let session = captureVM.lastCommittedSession else {
            stepForward = true
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { wizardStep = .process }
            return
        }
        capturedSession = session
        originalText = session.rawText
        currentText = session.rawText

        if let pipeline = postCapturePipelines.first(where: { $0.id == selectedPostCapturePipelineID }) {
            runPostCapturePipeline(pipeline)
        } else {
            stepForward = true
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { wizardStep = .process }
        }
    }

    private func runPostCapturePipeline(_ pipeline: FormattingPipeline) {
        isRunningPostCapture = true
        postCaptureError = nil
        let textToProcess = currentText
        postCaptureTask = Task { @MainActor in
            do {
                let result = try await DocumentFormattingService().formatToText(
                    sourceText: textToProcess, pipeline: pipeline)
                if !Task.isCancelled { currentText = result }
            } catch {
                if !Task.isCancelled {
                    postCaptureError = "Auto Cleanup failed: \(error.localizedDescription)"
                }
            }
            isRunningPostCapture = false
            postCaptureTask = nil
            if !Task.isCancelled {
                stepForward = true
                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { wizardStep = .process }
            }
        }
    }

    // MARK: - Process actions

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
                    sourceText: textToProcess, pipeline: pipeline)
                if !Task.isCancelled {
                    pipelineRuns.append(PipelineRun(pipelineName: pipelineName, result: result))
                }
            } catch {
                if !Task.isCancelled {
                    errorText = "Pipeline failed: \(error.localizedDescription)"
                }
            }
            isRunningPipeline = false
            runningPipelineTask = nil
        }
    }

    // MARK: - Navigation

    private func backFromProcess() {
        runningPipelineTask?.cancel()
        runningPipelineTask = nil
        if let session = capturedSession {
            modelContext.delete(session)
            try? modelContext.save()
            capturedSession = nil
        }
        originalText = ""
        currentText = ""
        pipelineRuns = []
        errorText = nil
        captureVM.reset()
        stepForward = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { wizardStep = .acquire }
    }

    private func cancel() {
        stopDictationIfActive()
        runningPipelineTask?.cancel()
        runningPipelineTask = nil
        postCaptureTask?.cancel()
        postCaptureTask = nil
        if !isEditMode, let session = capturedSession {
            modelContext.delete(session)
            try? modelContext.save()
            capturedSession = nil
        }
        captureVM.reset()
        dismiss()
    }

    private func accept() {
        stopDictationIfActive()
        guard let session = capturedSession else { dismiss(); return }
        session.rawText = finalText
        try? modelContext.save()
        dismiss()
    }

    // MARK: - Helpers

    private var formattedDuration: String {
        let t = Int(captureVM.recordingDuration)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private var acquireProgressLabel: String {
        switch captureVM.phase {
        case .transcribing:      return "Transcribing…"
        case .downloadingModels: return "Downloading speaker models (first use only)…"
        case .diarizing:         return "Identifying speakers…"
        case .saving:            return "Saving…"
        default:                 return ""
        }
    }
}

// MARK: - Pipeline run bubble

private struct PipelineRunBubble: View {
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

#Preview { @MainActor in
    let c = makePreviewContainer()
    let captureVM = previewCaptureVM(in: c)
    return MicrophoneWizardView(captureVM: captureVM)
        .modelContainer(c)
        .frame(width: 600, height: 560)
}
