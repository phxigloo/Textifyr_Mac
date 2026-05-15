import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

struct PDFInputView: View {
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

    @State private var selectedURL: URL?
    @State private var selectedFileName: String?
    @State private var totalPages: Int?
    @State private var startPage = 1
    @State private var endPage = 1
    @State private var extractedText = ""
    @State private var isExtracting = false
    @State private var showFilePicker = false
    @State private var showingCropView = false
    @State private var cropPageImage: CGImage?
    @State private var cropPageNumber = 1
    @State private var errorText: String?
    @State private var warningText: String?
    @State private var showCharLimitAlert = false

    var body: some View {
        Group {
            if wizardStep == .review {
                reviewPanel
            } else {
                acquireView
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            handleFileSelection(result)
        }
        .sheet(isPresented: $showingCropView) {
            if let image = cropPageImage {
                NavigationStack {
                    CroppableImageView(
                        image: image,
                        onCrop: { cropped in
                            showingCropView = false
                            Task { await processCroppedImage(cropped) }
                        },
                        onCancel: { showingCropView = false }
                    )
                    .navigationTitle("Crop PDF Page \(cropPageNumber)")
                }
                .frame(minWidth: 560, minHeight: 480)
            }
        }
        .alert("Character Limit Reached", isPresented: $showCharLimitAlert) {
            Button("OK") {}
        } message: {
            Text("The extracted text exceeds \(AppConstants.maxImportCharacters.formatted()) characters and has been truncated. Consider reducing the page range.")
        }
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { closeWizard() }
        }
    }

    // MARK: - Review panel (steps 2 & 3)

    private var reviewPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(.tint)
                Text("Import PDF")
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
                    captureVM.saveTextCapture(finalText, captureMethod: .pdf)
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
        VStack(spacing: 16) {
            Text("Import PDF")
                .font(.title2).bold()
                .padding(.top, 24)

            fileSelectionArea
                .padding(.horizontal)

            if let total = totalPages, total > 1 {
                pageRangeSelector(total: total)
                    .padding(.horizontal)
            }

            if isExtracting {
                ProgressView("Extracting text…").padding(.horizontal)
            }

            Divider()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $extractedText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)

                if extractedText.isEmpty && !isExtracting {
                    Text("Select a PDF, then use Extract Text to pull out selectable text, or set From and To to the same page number and use Crop Page to draw a region and recognise text from a photo or scan.")
                        .foregroundStyle(.secondary).font(.body)
                        .padding(.horizontal, 8).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)

            if let warning = warningText {
                Text(warning).font(.caption).foregroundStyle(.orange).padding(.horizontal)
            }
            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            pipelinePickerCard
                .padding(.horizontal)

            controlsBar
                .padding([.horizontal, .bottom])
        }
        .frame(maxWidth: .infinity, minHeight: 480)
    }

    // MARK: - File selection

    @ViewBuilder private var fileSelectionArea: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext").font(.title2).foregroundStyle(.secondary)

            if let name = selectedFileName {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline).lineLimit(1)
                    if let total = totalPages {
                        Text("\(total) page\(total == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No PDF selected").foregroundStyle(.secondary)
            }

            Spacer()

            Button("Choose PDF…") { showFilePicker = true }
                .buttonStyle(.bordered)
                .disabled(isExtracting)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Page range

    private var isPageRangeValid: Bool {
        guard let total = totalPages else { return true }
        return startPage >= 1 && startPage <= total
            && endPage >= startPage && endPage <= total
    }

    private var isSinglePageSelected: Bool { startPage == endPage && isPageRangeValid }

    @ViewBuilder
    private func pageRangeSelector(total: Int) -> some View {
        HStack(spacing: 12) {
            Text("Pages:").font(.subheadline).foregroundStyle(.secondary)
            Text("From").font(.subheadline)
            pageField(value: $startPage, total: total)
            Text("To").font(.subheadline)
            pageField(value: $endPage, total: total)
            Text("of \(total)").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private func pageField(value: Binding<Int>, total: Int) -> some View {
        let invalid = value.wrappedValue < 1 || value.wrappedValue > total
        TextField("", value: value, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(invalid ? Color.red : Color.clear, lineWidth: 1.5))
    }

    // MARK: - Controls

    @ViewBuilder private var controlsBar: some View {
        HStack(spacing: 16) {
            if selectedURL != nil && !isExtracting {
                Button("Crop Page") { cropAndShowPage() }
                    .buttonStyle(.bordered)
                    .disabled(!isSinglePageSelected)
                    .help(isSinglePageSelected ? "Crop a region of this page for OCR" : "Set From and To to the same page to crop")

                Button("Clear") { extractedText = "" }
                    .buttonStyle(.bordered)
                    .disabled(extractedText.isEmpty)
            }

            Spacer()

            Button("Cancel") { captureVM.reset(); closeWizard() }
                .buttonStyle(.bordered)

            if isExtracting {
                Button("Stop") { isExtracting = false }
                    .buttonStyle(.bordered)
            } else {
                Button("Extract Text") { Task { await extractText() } }
                    .buttonStyle(.bordered)
                    .disabled(selectedURL == nil || !isPageRangeValid)
            }

            Button("Continue") {
                proceedToReview(text: extractedText)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isExtracting || isRunningPostCapture || extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            selectedURL = url
            selectedFileName = url.lastPathComponent
            errorText = nil

            if let pages = PDFTextService.pageCount(for: url) {
                totalPages = pages
                startPage = 1
                endPage = min(pages, AppConstants.maxPDFPages)
                if pages > AppConstants.maxPDFPages {
                    warningText = "This PDF has \(pages) pages. Only the first \(AppConstants.maxPDFPages) pages can be extracted."
                } else {
                    warningText = nil
                }
            }

        case .failure(let error):
            errorText = error.localizedDescription
        }
    }

    private func extractText() async {
        guard let url = selectedURL, isPageRangeValid else { return }
        isExtracting = true
        errorText = nil
        let range = (startPage - 1)...(endPage - 1)
        do {
            let text = try PDFTextService.extractText(from: url, pageRange: range)
            extractedText = text
            if text.count >= AppConstants.maxImportCharacters {
                warningText = "Text was truncated to \(AppConstants.maxImportCharacters.formatted()) characters."
                showCharLimitAlert = true
            }
        } catch {
            errorText = error.localizedDescription
        }
        isExtracting = false
    }

    private func cropAndShowPage() {
        guard let url = selectedURL else { return }
        cropPageNumber = startPage
        if let image = PDFTextService.renderPage(from: url, pageIndex: startPage - 1) {
            cropPageImage = image
            showingCropView = true
        } else {
            errorText = "Could not render PDF page for cropping."
        }
    }

    private func processCroppedImage(_ cgImage: CGImage) async {
        guard !isExtracting else { return }
        isExtracting = true
        do {
            let text = try await VisionTextService.recognizeText(in: cgImage)
            if text.isEmpty {
                errorText = "No text detected in the cropped region."
            } else {
                let separator = "\n\n--- Crop (Page \(cropPageNumber)) ---\n\n"
                extractedText = extractedText.isEmpty ? text : extractedText + separator + text
            }
        } catch {
            errorText = error.localizedDescription
        }
        isExtracting = false
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let captureVM = previewCaptureVM(in: c)
    return PDFInputView(captureVM: captureVM)
        .modelContainer(c)
        .frame(width: 560, height: 500)
}
