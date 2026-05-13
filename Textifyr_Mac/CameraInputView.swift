import SwiftUI
import SwiftData
import AppKit
import AVFoundation
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

struct CameraInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.wizardDismiss) private var wizardDismiss
    private func closeWizard() { wizardDismiss != nil ? wizardDismiss!() : dismiss() }
    @EnvironmentObject private var appState: AppState

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

    @State private var capturedImage: NSImage?
    @State private var capturedCGImage: CGImage?
    @State private var recognizedText = ""
    @State private var isProcessing = false
    @State private var showingCropView = false
    @State private var errorText: String?

    var body: some View {
        Group {
            if wizardStep == .review {
                reviewPanel
            } else {
                VStack(spacing: 20) {
                    Text("Camera Capture")
                        .font(.title2).bold()
                        .padding(.top, 24)

                    if !recognizedText.isEmpty || (isProcessing && capturedCGImage != nil) {
                        reviewContent
                    } else if let image = capturedImage {
                        capturedContent(image)
                    } else {
                        livePreviewContent
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showingCropView) {
            if let cg = capturedCGImage {
                NavigationStack {
                    CroppableImageView(
                        image: cg,
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
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { closeWizard() }
        }
        .onAppear  { appState.setCameraInUse(true) }
        .onDisappear { appState.setCameraInUse(false) }
    }

    // MARK: - Review panel (steps 2 & 3)

    private var reviewPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "camera.fill")
                    .foregroundStyle(.tint)
                Text("Camera Capture")
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
                    captureVM.saveTextCapture(finalText, captureMethod: .camera)
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

    // MARK: - Live preview

    @ViewBuilder private var livePreviewContent: some View {
        CameraPreviewView(onCapture: { image in
            capturedImage = image
            capturedCGImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        })
        .frame(width: 440, height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 10))

        if let error = errorText {
            Text(error).font(.caption).foregroundStyle(.red)
        }

        Button("Cancel") { captureVM.reset(); closeWizard() }
            .buttonStyle(.bordered).padding(.bottom, 28)
    }

    // MARK: - Captured preview

    @ViewBuilder private func capturedContent(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable().scaledToFit()
            .frame(maxWidth: 440, maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 10))

        HStack(spacing: 16) {
            Button("Retake") { capturedImage = nil; capturedCGImage = nil; recognizedText = "" }
                .buttonStyle(.bordered)

            Button("Crop") { showingCropView = true }
                .buttonStyle(.borderedProminent)
                .disabled(capturedCGImage == nil)
        }

        if let error = errorText {
            Text(error).font(.caption).foregroundStyle(.red)
        }

        Button("Cancel") { captureVM.reset(); closeWizard() }
            .buttonStyle(.bordered).padding(.bottom, 28)
    }

    // MARK: - Acquire review (OCR text)

    @ViewBuilder private var reviewContent: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Recognised Text", systemImage: "text.viewfinder")
                    .font(.headline).foregroundStyle(.secondary)
                Spacer()
                if isProcessing { ProgressView().controlSize(.small) }

                Button("Crop Again") { showingCropView = true }
                    .buttonStyle(.bordered).disabled(capturedCGImage == nil)

                Button("Clear") { recognizedText = "" }
                    .buttonStyle(.bordered).disabled(recognizedText.isEmpty)

                Button("Retake") {
                    capturedImage = nil; capturedCGImage = nil; recognizedText = ""
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            Text("Crop again to add more regions to the text below.")
                .font(.caption).foregroundStyle(.tertiary).padding(.horizontal)

            TextEditor(text: $recognizedText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)

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

    // MARK: - Pipeline picker card

    @ViewBuilder private var pipelinePickerCard: some View {
        if !postCapturePipelines.isEmpty {
            VStack(spacing: 0) {
                LabeledContent("Auto Cleanup") {
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
            postCaptureTask = Task { @MainActor in
                do {
                    let result = try await DocumentFormattingService().formatToText(
                        sourceText: text, pipeline: pipeline,
                        onProgress: { [self] p in postCaptureProgress = p })
                    if !Task.isCancelled { capturedText = result }
                } catch {
                    if !Task.isCancelled {
                        postCaptureError = "Auto Cleanup failed: \(error.localizedDescription)"
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

    private func processCroppedImage(_ cgImage: CGImage) async {
        guard !isProcessing else { return }
        isProcessing = true
        errorText = nil
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

// MARK: - Live camera preview (NSViewRepresentable)

struct CameraPreviewView: NSViewRepresentable {
    let onCapture: (NSImage) -> Void

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.onCapture = onCapture
        return view
    }
    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {}
}

class CameraPreviewNSView: NSView {
    var onCapture: ((NSImage) -> Void)?

    private var session: AVCaptureSession?
    private var output: AVCapturePhotoOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startSession() }
    }

    private func startSession() {
        let session = AVCaptureSession()
        self.session = session

        // Prefer built-in cameras; exclude Continuity Camera per architecture spec.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video, position: .unspecified
        )
        guard let device = discovery.devices.first(where: { $0.deviceType != .continuityCamera })
                ?? discovery.devices.first,
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        session.addInput(input)
        let output = AVCapturePhotoOutput()
        self.output = output
        session.addOutput(output)

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        wantsLayer = true
        self.layer?.addSublayer(layer)
        previewLayer = layer

        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }

        let btn = NSButton(title: "Capture", target: self, action: #selector(capture))
        btn.bezelStyle = .rounded
        btn.frame = NSRect(x: (bounds.width - 90) / 2, y: 8, width: 90, height: 28)
        btn.autoresizingMask = [.minXMargin, .maxXMargin]
        addSubview(btn)
    }

    @objc private func capture() {
        output?.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
}

extension CameraPreviewNSView: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard let data = photo.fileDataRepresentation(),
              let image = NSImage(data: data) else { return }
        DispatchQueue.main.async { self.onCapture?(image) }
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let captureVM = previewCaptureVM(in: c)
    return CameraInputView(captureVM: captureVM)
        .modelContainer(c)
        .environmentObject(AppState())
        .frame(width: 520, height: 440)
}
