import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

struct AudioFileWizardView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    let captureMethod: CaptureMethod

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<FormattingPipeline> { $0.scopeRawValue == "postCapture" },
           sort: \FormattingPipeline.name) private var postCapturePipelines: [FormattingPipeline]

    private enum WizardStep { case settings, review }
    @State private var wizardStep: WizardStep = .settings
    @State private var stepForward = true
    @State private var reviewStepIndex = 1  // 1 = process, 2 = polish

    // Settings
    @State private var useTimeRange = false
    @State private var startTimeText = "0:00"
    @State private var endTimeText = ""
    @State private var selectedPostCapturePipelineID: PersistentIdentifier? = nil
    @State private var showFileImporter = false
    @State private var postCaptureError: String? = nil
    @State private var isRunningPostCapture = false
    @State private var postCaptureTask: Task<Void, Never>? = nil
    @State private var postCaptureProgress: DocumentFormattingService.Progress? = nil
    @State private var showPipelineEditor = false

    // Review state (passed to CaptureReviewStages)
    @State private var capturedSession: SourceSession? = nil
    @State private var originalText: String = ""
    @State private var initialText: String = ""

    private static let audioTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie]
    private static let postCapturePipelineKey = "defaultPostCapturePipelineName"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepContent
        }
        .frame(width: 600)
        .onAppear { restorePostCapturePipeline() }
        .onChange(of: captureVM.phase) { _, phase in handlePhaseChange(phase) }
        .onChange(of: postCapturePipelines) { _, pipelines in
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
        .sheet(isPresented: $showPipelineEditor) {
            PipelineEditorWindowView()
        }
    }

    private func restorePostCapturePipeline() {
        guard let name = UserDefaults.standard.string(forKey: Self.postCapturePipelineKey) else { return }
        selectedPostCapturePipelineID = postCapturePipelines.first { $0.name == name }?.id
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: captureMethod.systemImage)
                .foregroundStyle(.tint)
            Text(captureMethod == .videoAudio ? "Import Video" : "Import Audio File")
                .font(.title2).bold()
            Spacer()
            stepIndicator
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var stepIndicator: some View {
        let current = wizardStep == .settings ? 0 : reviewStepIndex
        return HStack(spacing: 0) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(current >= i ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: current == i ? 10 : 7, height: current == i ? 10 : 7)
                if i < 2 {
                    Rectangle()
                        .fill(current > i ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 32, height: 2)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
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
            case .settings:
                settingsStep.transition(stepTransition)
            case .review:
                CaptureReviewStages(
                    originalText: originalText,
                    initialText: initialText,
                    isEditMode: false,
                    reviewStepIndex: $reviewStepIndex,
                    onBack: { backFromReview() },
                    onCancel: { cancel() },
                    onAccept: { finalText in
                        capturedSession?.rawText = finalText
                        try? modelContext.save()
                        dismiss()
                    }
                )
                .transition(stepTransition)
            }
        }
        .clipped()
    }

    // MARK: - Step 1: Settings

    private var settingsStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Settings card
                    VStack(spacing: 0) {
                        Toggle("Identify Speakers", isOn: $captureVM.diarizationEnabled)
                            .disabled(captureVM.phase != .idle)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)

                        Divider().padding(.leading, 12)

                        Toggle("Specify time range", isOn: $useTimeRange)
                            .disabled(captureVM.phase != .idle)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)

                        if useTimeRange {
                            Divider().padding(.leading, 12)
                            timeRangeFields
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }

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

                            Divider().padding(.leading, 12)
                            HStack {
                                Spacer()
                                Button {
                                    showPipelineEditor = true
                                } label: {
                                    Label("Manage Pipelines…", systemImage: "slider.horizontal.3")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                        }
                    }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

                    // Supported formats
                    VStack(spacing: 2) {
                        Text("Audio: MP3 · M4A · WAV · AIFF · FLAC · AAC · CAF")
                            .font(.caption2).foregroundStyle(.secondary)
                        if captureMethod == .videoAudio {
                            Text("Video: MP4 · M4V · MOV (QuickTime) · AVI · MKV")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    // Transcription progress
                    if [.transcribing, .downloadingModels, .diarizing, .saving].contains(captureVM.phase) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                if captureVM.transcriptionFraction == nil {
                                    ProgressView().controlSize(.small)
                                }
                                Text(progressLabel)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let fraction = captureVM.transcriptionFraction {
                                ProgressView(value: fraction)
                                    .progressViewStyle(.linear)
                                    .animation(.linear(duration: 0.25), value: fraction)
                            }
                            if let chunk = captureVM.chunkProgress {
                                Text("Minutes \(chunk.minuteStart)–\(chunk.minuteEnd) of \(chunk.totalMinutes)")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .transition(.opacity)
                    }

                    // Auto-cleanup progress
                    if let p = postCaptureProgress {
                        PipelineProgressView(progress: p).transition(.opacity)
                    } else if isRunningPostCapture {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Starting…").font(.caption).foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    }

                    if let err = postCaptureError {
                        Text(err).font(.caption).foregroundStyle(.red).transition(.opacity)
                    }
                    if case .failed(let msg) = captureVM.phase {
                        Text(msg).font(.caption).foregroundStyle(.red).transition(.opacity)
                    }

                    // Inline speaker identification
                    if captureVM.phase == .identifySpeakers {
                        speakerIDContent
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(20)
                .animation(.spring(response: 0.35, dampingFraction: 0.9), value: captureVM.phase == .identifySpeakers)
                .animation(.easeInOut(duration: 0.2), value: isRunningPostCapture)
                .animation(.easeInOut(duration: 0.2), value: postCaptureError)
            }

            Divider()

            HStack {
                Button("Cancel") { cancel() }.buttonStyle(.bordered)
                if captureVM.phase == .identifySpeakers {
                    Button("Skip") { captureVM.skipSpeakerRename() }.buttonStyle(.bordered)
                }
                Spacer()
                settingsActionButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.audioTypes,
            allowsMultipleSelection: false
        ) { result in
            guard let url = try? result.get().first else { return }
            let range = useTimeRange ? parsedRange() : nil
            Task { await captureVM.processAudioFile(url, range: range) }
        }
    }

    @ViewBuilder
    private var settingsActionButton: some View {
        switch captureVM.phase {
        case .idle:
            Button("Choose File…") { showFileImporter = true }
                .buttonStyle(.borderedProminent)
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

    private var timeRangeFields: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Start (M:SS)").font(.caption).foregroundStyle(.secondary)
                TextField("0:00", text: $startTimeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("End (M:SS)").font(.caption).foregroundStyle(.secondary)
                TextField("end", text: $endTimeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
        }
    }

    // MARK: - Phase handling

    private func handlePhaseChange(_ phase: CapturePhase) {
        guard phase == .done else { return }
        guard let session = captureVM.lastCommittedSession else {
            transitionToReview()
            return
        }
        capturedSession = session
        originalText = session.rawText
        initialText = session.rawText

        if let pipeline = postCapturePipelines.first(where: { $0.id == selectedPostCapturePipelineID }) {
            runPostCapturePipeline(pipeline)
        } else {
            transitionToReview()
        }
    }

    private func runPostCapturePipeline(_ pipeline: FormattingPipeline) {
        isRunningPostCapture = true
        postCaptureError = nil
        let textToProcess = initialText
        postCaptureTask = Task { @MainActor in
            do {
                let result = try await DocumentFormattingService().formatToText(
                    sourceText: textToProcess, pipeline: pipeline,
                    onProgress: { [self] p in postCaptureProgress = p })
                if !Task.isCancelled { initialText = result }
            } catch {
                if !Task.isCancelled {
                    postCaptureError = "Auto Cleanup failed: \(error.localizedDescription)"
                }
            }
            isRunningPostCapture = false
            postCaptureProgress = nil
            postCaptureTask = nil
            if !Task.isCancelled { transitionToReview() }
        }
    }

    private func transitionToReview() {
        reviewStepIndex = 1
        stepForward = true
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { wizardStep = .review }
    }

    // MARK: - Navigation

    private func backFromReview() {
        if let session = capturedSession {
            modelContext.delete(session)
            try? modelContext.save()
            capturedSession = nil
        }
        originalText = ""
        initialText = ""
        captureVM.reset()
        stepForward = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { wizardStep = .settings }
    }

    private func cancel() {
        postCaptureTask?.cancel()
        postCaptureTask = nil
        if let session = capturedSession {
            modelContext.delete(session)
            try? modelContext.save()
            capturedSession = nil
        }
        captureVM.reset()
        dismiss()
    }

    // MARK: - Helpers

    private var progressLabel: String {
        switch captureVM.phase {
        case .transcribing:
            if let p = captureVM.chunkProgress {
                return "Transcribing \(p.totalMinutes)-min file…"
            }
            return "Transcribing…"
        case .downloadingModels: return "Downloading speaker models (first use only)…"
        case .diarizing:         return "Identifying speakers…"
        case .saving:            return "Saving…"
        default:                 return ""
        }
    }

    private func parsedRange() -> ClosedRange<TimeInterval>? {
        let start = parseTime(startTimeText) ?? 0
        guard let end = parseTime(endTimeText), end > start else { return nil }
        return start...end
    }

    private func parseTime(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        switch parts.count {
        case 1:
            guard let s = Double(parts[0]) else { return nil }
            return s
        case 2:
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60 + s
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        default:
            return nil
        }
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let captureVM = previewCaptureVM(in: c)
    return AudioFileWizardView(captureVM: captureVM, captureMethod: .audioFile)
        .modelContainer(c)
        .frame(width: 600, height: 560)
}
