import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

struct ImageFileImportView: View {
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

    @State private var loadedImages: [CGImage] = []
    @State private var recognizedText = ""
    @State private var isLoadingImages = false
    @State private var isProcessing = false
    @State private var showFileImporter = false
    @State private var showingCropView = false
    @State private var cropImageIndex = 0
    @State private var errorText: String?
    @State private var showActionEditor = false
    @State private var showDiscardConfirm = false

    private static let imageTypes: [UTType] = [.image, .png, .jpeg, .tiff, .bmp, .heic, .heif, .gif, .webP]

    var body: some View {
        Group {
            if wizardStep == .review {
                reviewPanel
            } else {
                VStack(spacing: 0) {
                    ToolColumnHeader("Import Image")

                    Group {
                        if loadedImages.isEmpty && !isLoadingImages {
                            selectionContent
                        } else if isLoadingImages {
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
                        if isProcessing || isRunningPostCapture || isLoadingImages {
                            ProgressView().controlSize(.small)
                        } else if loadedImages.isEmpty {
                            Button("Choose Image…") { showFileImporter = true }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Crop") { cropImageIndex = 0; showingCropView = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.imageTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): Task { await loadImageFiles(urls) }
            case .failure(let error): errorText = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingCropView) {
            if cropImageIndex < loadedImages.count {
                NavigationStack {
                    CroppableImageView(
                        image: loadedImages[cropImageIndex],
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
        .alert("Image Error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
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
    }

    // MARK: - Chrome helpers

    private var hasUnsavedCapture: Bool {
        wizardStep == .review || !loadedImages.isEmpty || isProcessing || isRunningPostCapture
            || !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Wizard step in the jump-bar (Phase 22.8): `Documents ▸ Document: <doc> ▸ Add Source ▸ Image [▸ Review]`.
    private func updateWizardBreadcrumb() {
        let docTitle = captureVM.document.title
        var crumbs: [BreadcrumbCrumb] = [
            BreadcrumbCrumb("Documents", target: .documents),
            BreadcrumbCrumb("Document: \(docTitle.isEmpty ? "Document" : docTitle)", target: .documents),
            BreadcrumbCrumb("Add Source"),
            BreadcrumbCrumb("Image"),
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
            ToolColumnHeader("Import Image")

            CaptureReviewStages(
                originalText: capturedText,
                initialText: capturedText,
                isEditMode: false,
                reviewStepIndex: $reviewStepIndex,
                onBack: {
                    // Retake: back to a fresh source selection.
                    postCaptureTask?.cancel()
                    loadedImages = []
                    recognizedText = ""
                    errorText = nil
                    reviewStepIndex = 1
                    wizardStep = .acquire
                },
                onCancel: { cancelWizard() },
                onAccept: { finalText, rtfData in
                    if let rtf = rtfData {
                        captureVM.saveRTFCapture(rtfData: rtf, plainText: finalText, captureMethod: .imageFile)
                    } else {
                        captureVM.saveTextCapture(finalText, captureMethod: .imageFile)
                    }
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Selection

    @ViewBuilder private var selectionContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.image")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("Open image files to extract text using OCR.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Supported: PNG, JPEG, TIFF, HEIC, BMP, GIF, WebP")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if let error = errorText { errorLabel(error) }
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Loading

    @ViewBuilder private var loadingContent: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Loading images…").font(.headline)
        }
        .frame(height: 200)
    }

    // MARK: - Acquire review (crop + recognized text)

    @ViewBuilder private var readyContent: some View {
        VStack(spacing: 12) {
            if let first = loadedImages.first {
                Image(nsImage: NSImage(cgImage: first, size: NSSize(width: first.width, height: first.height)))
                    .resizable().scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    .padding(.horizontal)
            }

            HStack {
                Text(loadedImages.count > 1 ? "\(loadedImages.count) images loaded" : "Image loaded")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open More") { loadedImages = []; recognizedText = ""; showFileImporter = true }
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

    private func loadImageFiles(_ urls: [URL]) async {
        isLoadingImages = true
        loadedImages = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url),
               let ns = NSImage(data: data),
               let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                loadedImages.append(cg)
            }
        }
        isLoadingImages = false

        if loadedImages.isEmpty {
            errorText = "Could not load any images from the selected file(s)."
        } else {
            cropImageIndex = 0
            showingCropView = true
        }
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
    return ImageFileImportView(captureVM: captureVM)
        .modelContainer(c)
        .frame(width: 560, height: 440)
}
