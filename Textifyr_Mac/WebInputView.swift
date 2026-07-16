import SwiftUI
import TextifyrModels
import TextifyrViewModels
import TextifyrServices
import SwiftData

struct WebInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.wizardDismiss) private var wizardDismiss
    @EnvironmentObject private var appState: AppState
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
    @State private var showActionEditor = false
    @State private var showDiscardConfirm = false

    @State private var stepForward = true

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: stepForward ? .trailing : .leading).combined(with: .opacity),
            removal:   .move(edge: stepForward ? .leading  : .trailing).combined(with: .opacity)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolColumnHeader("Import Web Page")

            ZStack {
                if wizardStep == .review {
                    CaptureReviewStages(
                        originalText: capturedText,
                        initialText: capturedText,
                        isEditMode: false,
                        reviewStepIndex: $reviewStepIndex,
                        onBack: {
                            postCaptureTask?.cancel()
                            reviewStepIndex = 1
                            stepForward = false
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { wizardStep = .acquire }
                        },
                        onCancel: { cancelWizard() },
                        onAccept: { finalText, rtfData in
                            if let rtf = rtfData {
                                captureVM.saveRTFCapture(rtfData: rtf, plainText: finalText, captureMethod: .webURL)
                            } else {
                                captureVM.saveTextCapture(finalText, captureMethod: .webURL)
                            }
                        },
                        onAcceptSplit: { parts in
                            captureVM.saveMultipleRTFCaptures(parts, captureMethod: .webURL)
                        }
                    )
                    .transition(stepTransition)
                } else {
                    acquireView.transition(stepTransition)
                }
            }
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showActionEditor) {
            ScopedPipelineEditorSheet(scope: .postCapture)
        }
        .alert("Character Limit Reached", isPresented: $showCharLimitAlert) {
            Button("OK") {}
        } message: {
            Text("The extracted text exceeds \(AppConstants.maxImportCharacters.formatted()) characters and has been truncated.")
        }
        .confirmationDialog("Discard this import?",
                            isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { cancelWizard() }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("The extracted text will be lost.")
        }
        .onAppear {
            updateWizardBreadcrumb()
            appState.captureWizardActive = true
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
        .onChange(of: appState.requestExitCapture) { _, req in
            guard req else { return }
            appState.requestExitCapture = false
            if hasUnsavedCapture { showDiscardConfirm = true } else { cancelWizard() }
        }
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { closeWizard() }
        }
    }

    // MARK: - Chrome helpers

    private var hasUnsavedCapture: Bool {
        wizardStep == .review || isLoading || isRunningPostCapture
    }

    /// Wizard step in the jump-bar (Phase 22.8): `Documents ▸ Document: <doc> ▸ Add Source ▸ Web Page [▸ Review]`.
    private func updateWizardBreadcrumb() {
        let docTitle = captureVM.document.title
        var crumbs: [BreadcrumbCrumb] = [
            BreadcrumbCrumb("Documents", target: .documents),
            BreadcrumbCrumb("Document: \(docTitle.isEmpty ? "Document" : docTitle)", target: .documents),
            BreadcrumbCrumb("Add Source"),
            BreadcrumbCrumb("Web Page"),
        ]
        if wizardStep == .review { crumbs.append(BreadcrumbCrumb("Review")) }
        appState.breadcrumb = crumbs
    }

    private func cancelWizard() {
        postCaptureTask?.cancel()
        postCaptureTask = nil
        captureVM.reset()
        closeWizard()
    }

    // MARK: - Acquire view

    private var acquireView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Image(systemName: "globe")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            TextField("https://…", text: $urlText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { importURL() }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

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
                }
                .padding(20)
            }

            ToolColumnFooter {
                Button("Cancel") { cancelWizard() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Import") { importURL() }
                    .buttonStyle(.borderedProminent)
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading || isRunningPostCapture)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pipeline picker card

    @ViewBuilder private var pipelinePickerCard: some View {
        VStack(spacing: 0) {
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
                    .disabled(isRunningPostCapture || postCapturePipelines.isEmpty)
                }
                Text("Actions are reusable recipes built from prompts.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12).padding(.vertical, 10)

            if let p = postCaptureProgress {
                Divider().padding(.leading, 12)
                PipelineProgressView(progress: p)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else if isRunningPostCapture {
                Divider().padding(.leading, 12)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Starting…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }

            if let err = postCaptureError {
                Divider().padding(.leading, 12)
                Text(err).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }

            Divider().padding(.leading, 12)
            HStack {
                Spacer()
                Button {
                    showActionEditor = true
                } label: {
                    Label("New or Edit Action…", systemImage: "slider.horizontal.3").font(.caption)
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
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
                    stepForward = true
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { wizardStep = .review }
                }
            }
        } else {
            reviewStepIndex = 1
            stepForward = true
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { wizardStep = .review }
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
