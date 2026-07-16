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

    @State private var capturedDisplays: [(name: String, image: CGImage)] = []
    @State private var selectedImage: CGImage?
    @State private var carouselIndex = 0
    @State private var recognizedText = ""
    @State private var isCapturing = false
    @State private var isProcessing = false
    @State private var showingCropView = false
    @State private var showPrepareStep = true
    @State private var suppressPrepare = false
    @State private var hasTriggeredCapture = false
    @State private var errorText: String?
    @State private var permissionDenied = false
    @State private var showActionEditor = false
    @State private var showDiscardConfirm = false

    private static let suppressKey = "suppressScreenCapturePrepareAlert"

    var body: some View {
        Group {
            if wizardStep == .review {
                reviewPanel
            } else {
                VStack(spacing: 0) {
                    ToolColumnHeader("Screen Capture")

                    Group {
                        if showPrepareStep {
                            prepareContent
                        } else if isCapturing {
                            capturingContent
                        } else if !capturedDisplays.isEmpty && selectedImage == nil {
                            carouselContent
                        } else if selectedImage != nil {
                            readyContent
                        } else {
                            idleContent
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    ToolColumnFooter {
                        Button("Cancel") { cancelWizard() }
                            .buttonStyle(.bordered)
                        Spacer()
                        acquireTrailingButtons
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
        .sheet(isPresented: $showActionEditor) {
            ScopedPipelineEditorSheet(scope: .postCapture)
        }
        .confirmationDialog("Discard this capture?",
                            isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { cancelWizard() }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("The captured screenshots and recognised text will be lost.")
        }
        .onAppear {
            updateWizardBreadcrumb()
            appState.captureWizardActive = true
            if !hasTriggeredCapture {
                hasTriggeredCapture = true
                if UserDefaults.standard.bool(forKey: Self.suppressKey) {
                    showPrepareStep = false
                    Task { try? await Task.sleep(for: .milliseconds(400)); await captureScreens() }
                }
                // else: showPrepareStep stays true, inline prepare content shown
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
        wizardStep == .review || !capturedDisplays.isEmpty || selectedImage != nil
            || isProcessing || isCapturing || isRunningPostCapture
            || !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Wizard step in the jump-bar (Phase 22.8): `Documents ▸ Document: <doc> ▸ Add Source ▸ Screen Capture [▸ Review]`.
    private func updateWizardBreadcrumb() {
        let docTitle = captureVM.document.title
        var crumbs: [BreadcrumbCrumb] = [
            BreadcrumbCrumb("Documents", target: .documents),
            BreadcrumbCrumb("Document: \(docTitle.isEmpty ? "Document" : docTitle)", target: .documents),
            BreadcrumbCrumb("Add Source"),
            BreadcrumbCrumb("Screen Capture"),
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
            ToolColumnHeader("Screen Capture")

            CaptureReviewStages(
                originalText: capturedText,
                initialText: capturedText,
                isEditMode: false,
                reviewStepIndex: $reviewStepIndex,
                onBack: {
                    // Retake: back to a fresh capture.
                    postCaptureTask?.cancel()
                    capturedDisplays = []
                    selectedImage = nil
                    recognizedText = ""
                    carouselIndex = 0
                    errorText = nil
                    showPrepareStep = !UserDefaults.standard.bool(forKey: Self.suppressKey)
                    reviewStepIndex = 1
                    wizardStep = .acquire
                },
                onCancel: { cancelWizard() },
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

    // MARK: - Content states

    // Prepare step shown inline (replaces the old prepare sheet popup)
    @ViewBuilder private var prepareContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 48)).foregroundStyle(.tint)

            Text("Prepare Your Screen")
                .font(.title3.bold())

            Text("Arrange the windows you want to capture before proceeding. Textifyr is automatically excluded from the screenshot.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)

            Toggle("Don't show this again", isOn: $suppressPrepare)
                .toggleStyle(.checkbox)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    // Idle — ready to capture (shown after prepare is dismissed, when suppress is on)
    @ViewBuilder private var idleContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("Capture a screenshot to extract text. Textifyr is automatically excluded.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)

            if permissionDenied {
                permissionDeniedView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Trailing toolbar buttons for the acquire step
    @ViewBuilder private var acquireTrailingButtons: some View {
        if showPrepareStep {
            Button("Capture Now") {
                if suppressPrepare { UserDefaults.standard.set(true, forKey: Self.suppressKey) }
                showPrepareStep = false
                Task { try? await Task.sleep(for: .milliseconds(300)); await captureScreens() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        } else if isCapturing {
            EmptyView()
        } else if !capturedDisplays.isEmpty && selectedImage == nil {
            HStack(spacing: 12) {
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
        } else if selectedImage != nil {
            if isProcessing || isRunningPostCapture {
                ProgressView().controlSize(.small)
            } else {
                Button("Crop") { showingCropView = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            // idle
            if permissionDenied {
                Button("Try Again") {
                    permissionDenied = false
                    errorText = nil
                    Task { await captureScreens() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Capture Screen") {
                    Task { await captureScreens() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
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
        }
        .padding(.horizontal)
    }

    // MARK: - Ready (captured screenshot → crop → OCR → review)

    @ViewBuilder private var readyContent: some View {
        VStack(spacing: 12) {
            if let img = selectedImage {
                Image(nsImage: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)))
                    .resizable().scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    .padding(.horizontal)
            }

            HStack {
                Text("Screenshot captured").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if capturedDisplays.count > 1 {
                    Button("Switch Display") { selectedImage = nil }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Button("Recapture") {
                    capturedDisplays = []; selectedImage = nil; recognizedText = ""; carouselIndex = 0
                    Task { await captureScreens() }
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

            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            pipelinePickerCard
                .padding(.horizontal)
                .padding(.bottom, 8)
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

            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")!
                )
            }
            .buttonStyle(.bordered)
        }
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
    return ScreenCaptureInputView(captureVM: captureVM)
        .modelContainer(c)
        .frame(width: 560, height: 460)
}
