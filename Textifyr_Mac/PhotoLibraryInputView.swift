import SwiftUI
import SwiftData
import PhotosUI
import AppKit
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

struct PhotoLibraryInputView: View {
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

    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var currentImage: CGImage? = nil
    @State private var recognizedText = ""
    @State private var isLoadingImage = false
    @State private var isProcessing = false
    @State private var showingCropView = false
    @State private var errorText: String?
    @State private var showActionEditor = false
    @State private var showDiscardConfirm = false

    var body: some View {
        Group {
            if wizardStep == .review {
                reviewPanel
            } else {
                VStack(spacing: 0) {
                    ToolColumnHeader("Photo Library")

                    Group {
                        if currentImage == nil && !isLoadingImage {
                            selectionContent
                        } else if isLoadingImage {
                            loadingContent
                        } else {
                            readyContent
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    ToolColumnFooter {
                        Button("Cancel") { cancelWizard() }
                            .buttonStyle(.bordered)
                        Spacer()
                        if isProcessing || isRunningPostCapture || isLoadingImage {
                            ProgressView().controlSize(.small)
                        } else if currentImage == nil {
                            PhotosPicker(
                                selection: $selectedItem,
                                matching: .images,
                                photoLibrary: .shared()
                            ) {
                                Label("Choose Photo…", systemImage: "photo.on.rectangle")
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Crop") { showingCropView = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showingCropView) {
            if let image = currentImage {
                NavigationStack {
                    CroppableImageView(
                        image: image,
                        onCrop: { cropped in
                            showingCropView = false
                            Task { await processCroppedImage(cropped) }
                        },
                        onCancel: { showingCropView = false }
                    )
                    .navigationTitle("Crop Region")
                }
                .frame(minWidth: 560, minHeight: 480)
            }
        }
        .alert("Photo Error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { errorText = nil }
        } message: { Text(errorText ?? "") }
        .sheet(isPresented: $showActionEditor) {
            ScopedPipelineEditorSheet(scope: .postCapture)
        }
        .confirmationDialog("Discard this capture?",
                            isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { cancelWizard() }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("The recognised text will be lost.")
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
        .onChange(of: selectedItem) { _, item in
            guard let item else { return }
            Task { await loadPickedPhoto(item) }
        }
    }

    // MARK: - Chrome helpers

    private var hasUnsavedCapture: Bool {
        wizardStep == .review || currentImage != nil || isProcessing || isRunningPostCapture
            || !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Wizard step in the jump-bar (Phase 22.8): `Documents ▸ Document: <doc> ▸ Add Source ▸ Photo Library [▸ Review]`.
    private func updateWizardBreadcrumb() {
        let docTitle = captureVM.document.title
        var crumbs: [BreadcrumbCrumb] = [
            BreadcrumbCrumb("Documents", target: .documents),
            BreadcrumbCrumb("Document: \(docTitle.isEmpty ? "Document" : docTitle)", target: .documents),
            BreadcrumbCrumb("Add Source"),
            BreadcrumbCrumb("Photo Library"),
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

    // MARK: - Review panel

    private var reviewPanel: some View {
        VStack(spacing: 0) {
            ToolColumnHeader("Photo Library")

            CaptureReviewStages(
                originalText: capturedText,
                initialText: capturedText,
                isEditMode: false,
                reviewStepIndex: $reviewStepIndex,
                onBack: {
                    // Retake: back to a fresh photo pick.
                    postCaptureTask?.cancel()
                    currentImage = nil
                    recognizedText = ""
                    errorText = nil
                    reviewStepIndex = 1
                    wizardStep = .acquire
                },
                onCancel: { cancelWizard() },
                onAccept: { finalText, rtfData in
                    if let rtf = rtfData {
                        captureVM.saveRTFCapture(rtfData: rtf, plainText: finalText, captureMethod: .photoLibrary)
                    } else {
                        captureVM.saveTextCapture(finalText, captureMethod: .photoLibrary)
                    }
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Selection

    @ViewBuilder private var selectionContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("Pick a photo from your library to extract text using OCR. Use \"Pick More\" after each photo to add additional ones.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error = errorText { errorLabel(error) }
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Loading

    @ViewBuilder private var loadingContent: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Loading photo…").font(.headline)
        }
        .frame(height: 200)
    }

    // MARK: - Acquire review (crop + recognized text)

    @ViewBuilder private var readyContent: some View {
        VStack(spacing: 12) {
            if let img = currentImage {
                Image(nsImage: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)))
                    .resizable().scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    .padding(.horizontal)
            }

            HStack {
                Text("Photo loaded").font(.caption).foregroundStyle(.secondary)
                Spacer()
                PhotosPicker(selection: $selectedItem, matching: .images, photoLibrary: .shared()) {
                    Text("Pick Another")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal)

            if isProcessing || isRunningPostCapture {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(isProcessing ? "Recognising text…" : "Running action…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Crop the region to recognise, then continue to review.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            if let error = errorText { errorLabel(error).padding(.horizontal) }

            pipelinePickerCard
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .padding(.top, 8)
    }

    // MARK: - Pipeline picker card

    @ViewBuilder private var pipelinePickerCard: some View {
        VStack(spacing: 0) {
            if !postCapturePipelines.isEmpty {
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
                        .disabled(isRunningPostCapture)
                    }
                    Text("Actions are reusable recipes built from prompts.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
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

                Divider().padding(.leading, 12)
            }
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

    private func errorLabel(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
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

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        isLoadingImage = true
        currentImage = nil
        defer { isLoadingImage = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let ns = NSImage(data: data),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorText = "Could not load the selected photo."
            return
        }
        currentImage = cg
        showingCropView = true
    }

    private func processCroppedImage(_ cgImage: CGImage) async {
        guard !isProcessing else { return }
        isProcessing = true
        errorText = nil
        do {
            let text = try await VisionTextService.recognizeText(in: cgImage)
            if text.isEmpty {
                errorText = "No text detected. Crop a different region."
            } else {
                // OCR done → run the After Capture action → straight to the review step.
                recognizedText = text
                isProcessing = false
                proceedToReview(text: text)
                return
            }
        } catch {
            errorText = error.localizedDescription
        }
        isProcessing = false
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let captureVM = previewCaptureVM(in: c)
    return PhotoLibraryInputView(captureVM: captureVM)
        .modelContainer(c)
        .frame(width: 560, height: 440)
}
