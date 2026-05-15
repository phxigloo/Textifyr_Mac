import SwiftUI
import TextifyrModels
import TextifyrViewModels
import TextifyrServices
import SwiftData

struct AppleIntelligenceInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.wizardDismiss) private var wizardDismiss
    private func closeWizard() { wizardDismiss != nil ? wizardDismiss!() : dismiss() }

    @Query(filter: #Predicate<FormattingPipeline> { $0.scopeRawValue == "postCapture" },
           sort: \FormattingPipeline.name) private var postCapturePipelines: [FormattingPipeline]

    private enum WizardStep { case acquire, review }
    @State private var wizardStep: WizardStep = .acquire
    @State private var reviewStepIndex = 1
    @State private var capturedText = ""
    @State private var selectedPostCapturePipelineID: PersistentIdentifier? = nil
    @State private var isRunningPostCapture = false
    @State private var postCaptureTask: Task<Void, Never>? = nil
    @State private var postCaptureProgress: DocumentFormattingService.Progress? = nil
    @State private var postCaptureError: String? = nil

    @StateObject private var aiService = SessionAIService()
    @State private var prompt = ""
    @State private var generatedText = ""
    @State private var isGenerating = false
    @State private var errorText: String?
    @FocusState private var promptFocused: Bool

    private var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    private var hasText: Bool {
        !generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if wizardStep == .review {
                reviewPanel
            } else {
                acquireView
            }
        }
        .onAppear { promptFocused = true }
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { closeWizard() }
        }
    }

    // MARK: - Review panel (steps 2 & 3)

    private var reviewPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.sparkles")
                    .foregroundStyle(.tint)
                Text("Apple Intelligence")
                    .font(.title2).bold()
                Spacer()
                stepDotsIndicator
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            CaptureReviewStages(
                originalText: capturedText,
                initialText: capturedText,
                isEditMode: false,
                reviewStepIndex: $reviewStepIndex,
                onBack: {
                    postCaptureTask?.cancel()
                    reviewStepIndex = 1
                    wizardStep = .acquire
                },
                onCancel: {
                    postCaptureTask?.cancel()
                    captureVM.reset()
                    closeWizard()
                },
                onAccept: { finalText in
                    captureVM.saveTextCapture(finalText, captureMethod: .appleIntelligence)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stepDotsIndicator: some View {
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

    // MARK: - Acquire view

    private var acquireView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "wand.and.sparkles")
                    .foregroundStyle(Color.accentColor)
                Text("Apple Intelligence")
                    .font(.title2).bold()
                Spacer()
                Button("Cancel") { captureVM.reset(); closeWizard() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prompt")
                            .font(.headline)
                        TextEditor(text: $prompt)
                            .font(.body)
                            .frame(minHeight: 80, maxHeight: 160)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .focused($promptFocused)

                        HStack {
                            if let error = errorText {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                            Spacer()
                            Button {
                                Task { await generate() }
                            } label: {
                                if isGenerating {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("Generating…")
                                    }
                                } else {
                                    Label(hasText ? "Regenerate" : "Generate", systemImage: "sparkles")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canGenerate)
                        }
                    }

                    if hasText || isGenerating {
                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Generated Text")
                                    .font(.headline)
                                Spacer()
                                if hasText {
                                    Button("Clear") { generatedText = "" }
                                        .buttonStyle(.bordered)
                                        .font(.caption)
                                }
                            }

                            TextEditor(text: $generatedText)
                                .font(.body)
                                .frame(minHeight: 120)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    pipelinePickerCard
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Continue") {
                    proceedToReview(text: generatedText)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasText || isRunningPostCapture)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pipeline picker card

    @ViewBuilder private var pipelinePickerCard: some View {
        if !postCapturePipelines.isEmpty {
            VStack(spacing: 0) {
                LabeledContent("After Capture") {
                    Picker("", selection: $selectedPostCapturePipelineID) {
                        Text("None").tag(nil as PersistentIdentifier?)
                        ForEach(postCapturePipelines) { p in
                            Text(p.name).tag(p.id as PersistentIdentifier?)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isRunningPostCapture)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                if let p = postCaptureProgress {
                    Divider().padding(.leading, 12)
                    PipelineProgressView(progress: p)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else if isRunningPostCapture {
                    Divider().padding(.leading, 12)
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Starting…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                if let err = postCaptureError {
                    Divider().padding(.leading, 12)
                    Text(err).font(.caption).foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - proceedToReview

    private func proceedToReview(text: String) {
        capturedText = text
        if let pipeline = postCapturePipelines.first(where: { $0.id == selectedPostCapturePipelineID }) {
            isRunningPostCapture = true
            postCaptureError = nil
            pipeline.usageCount += 1
            postCaptureTask = Task { @MainActor in
                do {
                    let result = try await DocumentFormattingService().formatToText(
                        sourceText: text, pipeline: pipeline,
                        onProgress: { [self] p in postCaptureProgress = p })
                    if !Task.isCancelled { capturedText = result }
                } catch {
                    if !Task.isCancelled {
                        postCaptureError = "After Capture failed: \(error.localizedDescription)"
                    }
                }
                isRunningPostCapture = false
                postCaptureProgress = nil
                postCaptureTask = nil
                if !Task.isCancelled {
                    reviewStepIndex = 1
                    wizardStep = .review
                }
            }
        } else {
            reviewStepIndex = 1
            wizardStep = .review
        }
    }

    // MARK: - Actions

    private func generate() async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isGenerating = true
        errorText = nil
        generatedText = ""
        do {
            let stream = try await aiService.send(trimmed)
            for await chunk in stream {
                generatedText += chunk
            }
        } catch {
            errorText = error.localizedDescription
        }
        isGenerating = false
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let captureVM = previewCaptureVM(in: c)
    return AppleIntelligenceInputView(captureVM: captureVM)
        .modelContainer(c)
}
