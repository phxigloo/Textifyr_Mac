import SwiftUI
import SwiftData
import AppKit
import Combine
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

struct MicrophoneWizardView: View {
    @ObservedObject private var captureVM: InputCaptureViewModel
    private let initialSession: SourceSession?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.wizardDismiss) private var wizardDismiss
    @Environment(\.modelContext) private var modelContext

    private func closeWizard() { wizardDismiss != nil ? wizardDismiss!() : dismiss() }

    @Query(filter: #Predicate<FormattingPipeline> { $0.scopeRawValue == "postCapture" },
           sort: \FormattingPipeline.name) private var postCapturePipelines: [FormattingPipeline]

    private enum WizardStep { case acquire, review }
    @State private var wizardStep: WizardStep = .acquire
    @State private var stepForward = true
    @State private var reviewStepIndex = 1  // 1 = process, 2 = polish

    // Acquire
    @State private var selectedPostCapturePipelineID: PersistentIdentifier? = nil
    @State private var isRunningPostCapture = false
    @State private var postCaptureTask: Task<Void, Never>? = nil
    @State private var postCaptureError: String? = nil
    @State private var postCaptureProgress: DocumentFormattingService.Progress? = nil
    @State private var showActionEditor = false
    @State private var showDiscardConfirm = false
    @EnvironmentObject private var appState: AppState

    // Session & text (passed to CaptureReviewStages)
    @State private var capturedSession: SourceSession? = nil
    @State private var originalText: String = ""
    @State private var initialText: String = ""
    @State private var initialRTFData: Data? = nil

    private var isEditMode: Bool { initialSession != nil }
    private static let postCapturePipelineKey = "defaultPostCapturePipelineName"

    init(captureVM: InputCaptureViewModel, initialSession: SourceSession? = nil) {
        self._captureVM = ObservedObject(wrappedValue: captureVM)
        self.initialSession = initialSession
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolColumnHeader(title)
            stepContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            restorePostCapturePipeline()
            updateWizardBreadcrumb()
            appState.captureWizardActive = true
            if let session = initialSession {
                capturedSession = session
                originalText = session.rawText
                initialText = session.rawText
                initialRTFData = session.rawRTFData
                reviewStepIndex = 1
                wizardStep = .review
            }
        }
        .onChange(of: wizardStep) { _, _ in updateWizardBreadcrumb() }
        .onDisappear {
            appState.captureWizardActive = false
            if appState.workspaceMode == .documents {
                appState.breadcrumb = [
                    BreadcrumbCrumb("Documents", targetMode: .documents),
                    BreadcrumbCrumb(captureVM.document.title, targetMode: .documents),
                ]
            }
        }
        // A document-level breadcrumb was clicked — discard any in-progress recording (with a
        // confirmation) then close back to the source list.
        .onChange(of: appState.requestExitCapture) { _, req in
            guard req else { return }
            appState.requestExitCapture = false
            if hasUnsavedCapture { showDiscardConfirm = true } else { cancel() }
        }
        .confirmationDialog("Discard this recording?",
                            isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { cancel() }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("The recording and its transcript will be lost.")
        }
        // Build/edit an After Capture action over the wizard; new actions appear in the picker
        // on dismiss (the picker is a live @Query).
        .sheet(isPresented: $showActionEditor) {
            ScopedPipelineEditorSheet(scope: .postCapture)
        }
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
    }

    private func restorePostCapturePipeline() {
        guard let name = UserDefaults.standard.string(forKey: Self.postCapturePipelineKey) else { return }
        selectedPostCapturePipelineID = postCapturePipelines.first { $0.name == name }?.id
    }

    // MARK: - Chrome

    private var title: String { isEditMode ? "Edit Recording" : "New Recording" }

    /// Is there capture work that leaving would throw away? True once a transcript exists (review)
    /// or a recording/transcription is running. False on the untouched acquire step.
    private var hasUnsavedCapture: Bool {
        if wizardStep == .review || capturedSession != nil { return true }
        switch captureVM.phase {
        case .idle, .failed, .done: return false
        default: return true
        }
    }

    /// The wizard's step lives in the jump-bar, not a 1-2-3 dot indicator (Phase 22.8):
    /// `Documents ▸ Document: <doc> ▸ Add Source ▸ Microphone [▸ Review]`. The wizard's own crumbs
    /// are plain text — leaving mid-capture discards the recording, so that stays behind Back/Cancel.
    private func updateWizardBreadcrumb() {
        let docTitle = captureVM.document.title
        var crumbs: [BreadcrumbCrumb] = [
            BreadcrumbCrumb("Documents", target: .documents),
            BreadcrumbCrumb("Document: \(docTitle.isEmpty ? "Document" : docTitle)", target: .documents),
            BreadcrumbCrumb("Add Source"),
            BreadcrumbCrumb("Microphone"),
        ]
        if wizardStep == .review { crumbs.append(BreadcrumbCrumb("Review")) }
        appState.breadcrumb = crumbs
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
            case .acquire:
                acquireStep.transition(stepTransition)
            case .review:
                CaptureReviewStages(
                    originalText: originalText,
                    initialText: initialText,
                    initialRTFData: initialRTFData,
                    isEditMode: isEditMode,
                    showAutoStoppedBanner: captureVM.recordingAutoStopped,
                    reviewStepIndex: $reviewStepIndex,
                    onBack: isEditMode ? nil : { backFromReview() },
                    onCancel: { cancel() },
                    onAccept: { finalText, rtfData in
                        capturedSession?.rawText = finalText
                        if let rtf = rtfData { capturedSession?.rawRTFData = rtf }
                        try? modelContext.save()
                        closeWizard()
                    },
                    onAcceptSplit: { parts in
                        guard let session = capturedSession else { return }
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
                            modelContext.insert(newSession)
                            newSession.document = session.document
                            session.document?.sourceSessions = (session.document?.sourceSessions ?? []) + [newSession]
                        }
                        session.document?.modificationDate = Date()
                        try? modelContext.save()
                        closeWizard()
                    }
                )
                .transition(stepTransition)
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

                    // Recording limit warning
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

                    // Settings card
                    VStack(spacing: 0) {
                        Toggle("Identify Speakers", isOn: $captureVM.diarizationEnabled)
                            .disabled(captureVM.phase != .idle)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)

                        if !postCapturePipelines.isEmpty {
                            Divider().padding(.leading, 12)
                            VStack(spacing: 6) {
                                HStack(spacing: 8) {
                                    Text("After Capture, run Action")
                                    Picker("", selection: $selectedPostCapturePipelineID) {
                                        Text("Nothing").tag(nil as PersistentIdentifier?)
                                        ForEach(postCapturePipelines) { p in
                                            Text(p.name).tag(p.id as PersistentIdentifier?)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .fixedSize()
                                    .disabled(captureVM.phase != .idle)
                                }
                                Text("Actions are reusable recipes built from prompts.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                        Divider().padding(.leading, 12)
                        HStack {
                            Spacer()
                            Button {
                                showActionEditor = true
                            } label: {
                                Label("New or Edit Action…", systemImage: "slider.horizontal.3")
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
                    if let p = postCaptureProgress {
                        PipelineProgressView(progress: p).transition(.opacity)
                    } else if isRunningPostCapture {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Starting…").font(.caption).foregroundStyle(.secondary)
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

            ToolColumnFooter {
                Button("Cancel") { cancel() }.buttonStyle(.bordered)
                if captureVM.phase == .identifySpeakers {
                    Button("Skip") { captureVM.skipSpeakerRename() }.buttonStyle(.bordered)
                }
                Spacer()
                acquireActionButton
            }
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
        capturedSession?.rawRTFData = MarkdownRenderer.toRTF(initialText) ?? capturedSession?.rawRTFData
        try? modelContext.save()

        if let pipeline = postCapturePipelines.first(where: { $0.id == selectedPostCapturePipelineID }) {
            runPostCapturePipeline(pipeline)
        } else {
            transitionToReview()
        }
    }

    private func runPostCapturePipeline(_ pipeline: FormattingPipeline) {
        pipeline.usageCount += 1
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
                    postCaptureError = "After Capture failed: \(error.localizedDescription)"
                }
            }
            isRunningPostCapture = false
            postCaptureProgress = nil
            postCaptureTask = nil
            if !Task.isCancelled { transitionToReview() }
        }
    }

    private func transitionToReview() {
        initialRTFData = capturedSession?.rawRTFData
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
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { wizardStep = .acquire }
    }

    private func cancel() {
        postCaptureTask?.cancel()
        postCaptureTask = nil
        if !isEditMode, let session = capturedSession {
            modelContext.delete(session)
            try? modelContext.save()
            capturedSession = nil
        }
        captureVM.reset()
        closeWizard()
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

#Preview { @MainActor in
    let c = makePreviewContainer()
    let captureVM = previewCaptureVM(in: c)
    return MicrophoneWizardView(captureVM: captureVM)
        .modelContainer(c)
        .frame(width: 600, height: 560)
}
