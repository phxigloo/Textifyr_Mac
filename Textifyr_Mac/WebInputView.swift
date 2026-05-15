import SwiftUI
import TextifyrModels
import TextifyrViewModels
import TextifyrServices
import SwiftData

struct WebInputView: View {
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

    @State private var urlText = ""
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var warningText: String? = nil
    @State private var showCharLimitAlert = false

    var body: some View {
        Group {
            if wizardStep == .review {
                reviewPanel
            } else {
                acquireView
            }
        }
        .alert("Character Limit Reached", isPresented: $showCharLimitAlert) {
            Button("OK") {}
        } message: {
            Text("The extracted text exceeds \(AppConstants.maxImportCharacters.formatted()) characters and has been truncated.")
        }
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { closeWizard() }
        }
    }

    // MARK: - Review panel (steps 2 & 3)

    private var reviewPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(.tint)
                Text("Import Web Page")
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
                    captureVM.saveTextCapture(finalText, captureMethod: .webURL)
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
        VStack(spacing: 20) {
            Text("Import Web Page")
                .font(.title2).bold()
                .padding(.top, 24)

            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            TextField("https://…", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 24)
                .onSubmit { importURL() }

            if let warning = warningText {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Extracting text…").font(.caption).foregroundStyle(.secondary)
                }
            }

            pipelinePickerCard
                .padding(.horizontal, 24)

            HStack(spacing: 16) {
                Button("Cancel") {
                    captureVM.reset()
                    closeWizard()
                }
                .buttonStyle(.bordered)

                Button("Import") {
                    importURL()
                }
                .buttonStyle(.borderedProminent)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading || isRunningPostCapture)
            }
            .padding(.bottom, 28)
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

    private func importURL() {
        var raw = urlText.trimmingCharacters(in: .whitespaces)
        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") {
            raw = "https://" + raw
        }
        guard let url = URL(string: raw) else {
            errorText = "Invalid URL"
            return
        }
        errorText = nil
        isLoading = true
        Task {
            do {
                var text = try await WebExtractionService.extractText(from: url)
                isLoading = false
                if text.count > AppConstants.maxImportCharacters {
                    text = String(text.prefix(AppConstants.maxImportCharacters))
                    warningText = "Text was truncated to \(AppConstants.maxImportCharacters.formatted()) characters."
                    showCharLimitAlert = true
                } else {
                    warningText = nil
                }
                proceedToReview(text: text)
            } catch {
                errorText = error.localizedDescription
                isLoading = false
            }
        }
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let captureVM = previewCaptureVM(in: c)
    return WebInputView(captureVM: captureVM)
        .modelContainer(c)
        .frame(width: 500, height: 360)
}
