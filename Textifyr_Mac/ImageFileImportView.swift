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

    private static let imageTypes: [UTType] = [.image, .png, .jpeg, .tiff, .bmp, .heic, .heif, .gif, .webP]

    var body: some View {
        Group {
            if wizardStep == .review {
                reviewPanel
            } else {
                VStack(spacing: 20) {
                    Text("Import Image")
                        .font(.title2).bold()
                        .padding(.top, 24)

                    if loadedImages.isEmpty && !isLoadingImages {
                        selectionContent
                    } else if isLoadingImages {
                        loadingContent
                    } else {
                        reviewContent
                    }
                }
                .frame(maxWidth: .infinity)
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
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { closeWizard() }
        }
    }

    // MARK: - Review panel (steps 2 & 3)

    private var reviewPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.image")
                    .foregroundStyle(.tint)
                Text("Import Image")
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
                onAccept: { finalText, _ in
                    captureVM.saveTextCapture(finalText, captureMethod: .imageFile)
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

            Button("Choose Image…") { showFileImporter = true }
                .buttonStyle(.borderedProminent)

            Button("Cancel") { captureVM.reset(); closeWizard() }
                .buttonStyle(.bordered)
                .padding(.bottom, 28)
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

    @ViewBuilder private var reviewContent: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Recognised Text", systemImage: "text.viewfinder")
                    .font(.headline).foregroundStyle(.secondary)

                Spacer()

                if isProcessing { ProgressView().controlSize(.small) }

                if loadedImages.count > 1 {
                    Menu("Crop Image") {
                        ForEach(0..<loadedImages.count, id: \.self) { i in
                            Button("Image \(i + 1)") { cropImageIndex = i; showingCropView = true }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                } else {
                    Button("Crop") { cropImageIndex = 0; showingCropView = true }
                        .buttonStyle(.bordered)
                }

                Button("Clear") { recognizedText = "" }
                    .buttonStyle(.bordered)
                    .disabled(recognizedText.isEmpty)

                Button("Open More") { loadedImages = []; recognizedText = ""; showFileImporter = true }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            Text("Crop to select regions for OCR. Each crop appends to the text below.")
                .font(.caption).foregroundStyle(.tertiary).padding(.horizontal)

            if recognizedText.isEmpty && !isProcessing {
                Text("No text yet — use Crop to recognise a region.")
                    .font(.body).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                TextEditor(text: $recognizedText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
            }

            if let error = errorText { errorLabel(error).padding(.horizontal) }

            pipelinePickerCard
                .padding(.horizontal)

            HStack {
                Button("Cancel") { captureVM.reset(); closeWizard() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Continue") {
                    proceedToReview(text: recognizedText)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing || isRunningPostCapture)
            }
            .padding([.horizontal, .bottom])
        }
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
        do {
            let text = try await VisionTextService.recognizeText(in: cgImage)
            if text.isEmpty {
                errorText = "No text detected in the cropped region."
            } else {
                recognizedText = recognizedText.isEmpty ? text : recognizedText + "\n\n--- Crop ---\n\n" + text
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
