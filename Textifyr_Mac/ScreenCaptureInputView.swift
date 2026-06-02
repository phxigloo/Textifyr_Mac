import SwiftUI
import SwiftData
import AppKit
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

struct ScreenCaptureInputView: View {
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

    @State private var capturedDisplays: [(name: String, image: CGImage)] = []
    @State private var selectedImage: CGImage?
    @State private var carouselIndex = 0
    @State private var recognizedText = ""
    @State private var isCapturing = false
    @State private var isProcessing = false
    @State private var showingCropView = false
    @State private var showPrepareSheet = false
    @State private var suppressPrepare = false
    @State private var hasTriggeredCapture = false
    @State private var errorText: String?
    @State private var permissionDenied = false

    private static let suppressKey = "suppressScreenCapturePrepareAlert"

    var body: some View {
        Group {
            if wizardStep == .review {
                reviewPanel
            } else {
                VStack(spacing: 20) {
                    Text("Screen Capture")
                        .font(.title2).bold()
                        .padding(.top, 24)

                    if isCapturing {
                        capturingContent
                    } else if !capturedDisplays.isEmpty && selectedImage == nil {
                        carouselContent
                    } else if selectedImage != nil {
                        reviewContent
                    } else {
                        promptContent
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showPrepareSheet) {
            prepareSheet
        }
        .sheet(isPresented: $showingCropView) {
            if let image = selectedImage {
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
                .frame(minWidth: 640, minHeight: 500)
            }
        }
        .alert("Capture Error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { errorText = nil }
        } message: { Text(errorText ?? "") }
        .onAppear {
            if !hasTriggeredCapture {
                hasTriggeredCapture = true
                if UserDefaults.standard.bool(forKey: Self.suppressKey) {
                    Task { try? await Task.sleep(for: .milliseconds(400)); await captureScreens() }
                } else {
                    showPrepareSheet = true
                }
            }
        }
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { closeWizard() }
        }
    }

    // MARK: - Review panel (steps 2 & 3)

    private var reviewPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .foregroundStyle(.tint)
                Text("Screen Capture")
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
                onAccept: { finalText, rtfData in
                    if let rtf = rtfData {
                        captureVM.saveRTFCapture(rtfData: rtf, plainText: finalText, captureMethod: .screenCapture)
                    } else {
                        captureVM.saveTextCapture(finalText, captureMethod: .screenCapture)
                    }
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

    // MARK: - Content states

    @ViewBuilder private var promptContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("Capture a screenshot to extract text. Textifyr is automatically excluded.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)

            if permissionDenied {
                permissionDeniedView
            } else {
                if let error = errorText { Text(error).font(.caption).foregroundStyle(.red) }

                Button("Capture Screen") {
                    if UserDefaults.standard.bool(forKey: Self.suppressKey) {
                        Task { await captureScreens() }
                    } else {
                        showPrepareSheet = true
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Cancel") { captureVM.reset(); closeWizard() }
                .buttonStyle(.bordered).padding(.bottom, 28)
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder private var capturingContent: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Capturing…").font(.headline)
        }
        .frame(height: 200)
    }

    // MARK: - Multi-display carousel

    @ViewBuilder private var carouselContent: some View {
        VStack(spacing: 12) {
            Text("Select Display")
                .font(.headline)

            Text("\(capturedDisplays[carouselIndex].name)")
                .font(.subheadline).foregroundStyle(.secondary)

            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { carouselIndex = max(carouselIndex - 1, 0) }
                } label: {
                    Image(systemName: "chevron.left").font(.title2.bold())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(carouselIndex == 0)
                .opacity(carouselIndex == 0 ? 0.3 : 1)

                let img = capturedDisplays[carouselIndex].image
                Image(nsImage: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)))
                    .resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    .padding(.horizontal, 8)
                    .id(carouselIndex)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { carouselIndex = min(carouselIndex + 1, capturedDisplays.count - 1) }
                } label: {
                    Image(systemName: "chevron.right").font(.title2.bold())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(carouselIndex >= capturedDisplays.count - 1)
                .opacity(carouselIndex >= capturedDisplays.count - 1 ? 0.3 : 1)
            }

            HStack(spacing: 8) {
                ForEach(capturedDisplays.indices, id: \.self) { i in
                    Circle()
                        .fill(i == carouselIndex ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                        .onTapGesture { withAnimation { carouselIndex = i } }
                }
            }

            HStack(spacing: 16) {
                Button("Recapture") {
                    capturedDisplays = []; carouselIndex = 0
                    Task { await captureScreens() }
                }
                .buttonStyle(.bordered)

                Button {
                    selectedImage = capturedDisplays[carouselIndex].image
                    showingCropView = true
                } label: {
                    Label("Use This Display", systemImage: "crop")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal)
    }

    // MARK: - Acquire review (crop + text)

    @ViewBuilder private var reviewContent: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Recognised Text", systemImage: "text.viewfinder")
                    .font(.headline).foregroundStyle(.secondary)
                Spacer()
                if isProcessing { ProgressView().controlSize(.small) }

                Button("Crop") { showingCropView = true }.buttonStyle(.bordered)

                Button("Clear") { recognizedText = "" }
                    .buttonStyle(.bordered).disabled(recognizedText.isEmpty)

                if capturedDisplays.count > 1 {
                    Button("Switch Display") { selectedImage = nil }.buttonStyle(.bordered)
                }

                Button("Recapture") {
                    capturedDisplays = []; selectedImage = nil; recognizedText = ""; carouselIndex = 0
                    Task { await captureScreens() }
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            Text("Crop to select regions for OCR. Each crop appends to the text below.")
                .font(.caption).foregroundStyle(.tertiary).padding(.horizontal)

            if recognizedText.isEmpty && !isProcessing {
                Text("No text yet — use Crop to recognise a region.")
                    .font(.body).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                TextEditor(text: $recognizedText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
            }

            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            pipelinePickerCard
                .padding(.horizontal)

            HStack {
                Button("Cancel") { captureVM.reset(); closeWizard() }.buttonStyle(.bordered)
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

    // MARK: - Permission denied

    @ViewBuilder private var permissionDeniedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text("Screen Recording Permission Required")
                .font(.headline)

            Text("Textifyr needs Screen Recording access to capture your screen. Grant it in System Settings, then try again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")!
                    )
                }
                .buttonStyle(.borderedProminent)

                Button("Try Again") {
                    permissionDenied = false
                    errorText = nil
                    Task { await captureScreens() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Prepare sheet

    @ViewBuilder private var prepareSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 40)).foregroundStyle(.tint)

            Text("Prepare Your Screen")
                .font(.title3.bold())

            Text("Arrange the windows you want to capture before proceeding. Textifyr is automatically excluded from the screenshot.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 20)

            Toggle("Don't show this again", isOn: $suppressPrepare)
                .toggleStyle(.checkbox).padding(.top, 4)

            HStack(spacing: 12) {
                Button("Cancel") { showPrepareSheet = false }
                    .buttonStyle(.bordered).keyboardShortcut(.cancelAction)

                Button("Capture Now") {
                    if suppressPrepare { UserDefaults.standard.set(true, forKey: Self.suppressKey) }
                    showPrepareSheet = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        await captureScreens()
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24).frame(width: 380)
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

    private func captureScreens() async {
        isCapturing = true
        errorText = nil
        do {
            let results = try await ScreenCaptureService.captureAllDisplays()
            isCapturing = false
            if results.count == 1 {
                selectedImage = results[0].image
                showingCropView = true
            } else {
                capturedDisplays = results
                carouselIndex = 0
            }
        } catch {
            isCapturing = false
            let desc = error.localizedDescription.lowercased()
            if desc.contains("tcc") || desc.contains("declined") || desc.contains("not authorized") || desc.contains("permission") {
                permissionDenied = true
            } else {
                errorText = "Screen capture failed: \(error.localizedDescription)"
            }
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
    return ScreenCaptureInputView(captureVM: captureVM)
        .modelContainer(c)
        .frame(width: 560, height: 460)
}
