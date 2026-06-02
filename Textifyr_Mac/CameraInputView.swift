import SwiftUI
import SwiftData
import AppKit
import AVFoundation
import Combine
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

// MARK: - Capture Trigger

final class CameraCaptureTrigger: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    weak var view: CameraPreviewNSView?
    func capture() { view?.capturePhoto() }
}

// MARK: - Main View

struct CameraInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.wizardDismiss) private var wizardDismiss
    @EnvironmentObject private var appState: AppState

    private func closeWizard() { wizardDismiss != nil ? wizardDismiss!() : dismiss() }

    @Query(filter: #Predicate<FormattingPipeline> { $0.scopeRawValue == "postCapture" },
           sort: \FormattingPipeline.name) private var postCapturePipelines: [FormattingPipeline]

    private enum WizardStep { case acquire, review }
    @State private var wizardStep: WizardStep = .acquire
    @State private var stepForward = true
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
    @State private var isCapturing = false
    @State private var showingCropView = false
    @State private var errorText: String?

    @StateObject private var captureTrigger = CameraCaptureTrigger()

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingCropView) {
            if let cg = capturedCGImage {
                NavigationStack {
                    CroppableImageView(
                        image: cg,
                        onCrop: { cropped in
                            showingCropView = false
                            Task { await processCroppedImage(cropped) }
                        },
                        onCancel: {
                            showingCropView = false
                        }
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.fill")
                .foregroundStyle(.tint)
            Text("Camera")
                .font(.title2).bold()
            Spacer()
            stepDotsIndicator
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var stepDotsIndicator: some View {
        let current = wizardStep == .acquire ? 0 : reviewStepIndex
        return HStack(spacing: 0) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(current >= i ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: current == i ? 10 : 7, height: current == i ? 10 : 7)
                if i < 2 {
                    Rectangle()
                        .fill(current > i ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 32, height: 2)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: stepForward ? .trailing : .leading).combined(with: .opacity),
            removal:   .move(edge: stepForward ? .leading  : .trailing).combined(with: .opacity)
        )
    }

    // MARK: - Step dispatch

    @ViewBuilder
    private var stepContent: some View {
        ZStack {
            switch wizardStep {
            case .acquire:
                acquireStep
                    .transition(stepTransition)
            case .review:
                CaptureReviewStages(
                    originalText: capturedText,
                    initialText: capturedText,
                    isEditMode: false,
                    reviewStepIndex: $reviewStepIndex,
                    onBack: {
                        postCaptureTask?.cancel()
                        reviewStepIndex = 1
                        stepForward = false
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                            wizardStep = .acquire
                        }
                    },
                    onCancel: {
                        postCaptureTask?.cancel()
                        captureVM.reset()
                        closeWizard()
                    },
                    onAccept: { finalText, rtfData in
                        if let rtf = rtfData {
                            captureVM.saveRTFCapture(rtfData: rtf, plainText: finalText, captureMethod: .camera)
                        } else {
                            captureVM.saveTextCapture(finalText, captureMethod: .camera)
                        }
                    }
                )
                .transition(stepTransition)
            }
        }
        .clipped()
    }

    // MARK: - Step 1: Acquire

    private var acquireStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    livePreviewOrResult
                    pipelinePickerCard
                }
                .padding(20)
            }

            Divider()
            acquireTaskBar
        }
    }

    // MARK: - Live preview / captured / OCR result

    @ViewBuilder
    private var livePreviewOrResult: some View {
        if !recognizedText.isEmpty || (isProcessing && capturedCGImage != nil) {
            ocrResultContent
        } else if capturedImage != nil {
            capturedImageContent
        } else {
            liveCameraContent
        }
    }

    @ViewBuilder
    private var liveCameraContent: some View {
        VStack(spacing: 12) {
            if availableCameras.count > 1 {
                HStack {
                    Text("Camera:").font(.subheadline).foregroundStyle(.secondary)
                    Picker("", selection: $selectedCameraIndex) {
                        ForEach(availableCameras.indices, id: \.self) { i in
                            Text(availableCameras[i].localizedName).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedCameraIndex) { _, newIndex in
                        let device = availableCameras[newIndex]
                        cameraPreviewRef?.switchCamera(to: device)
                    }
                    Spacer()
                }
            }

            CameraPreviewView(
                captureTrigger: captureTrigger,
                onCapture: { image in
                    capturedImage = image
                    capturedCGImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    isCapturing = false
                    showingCropView = true
                },
                onViewCreated: { nsView in
                    cameraPreviewRef = nsView
                    availableCameras = nsView.availableCameras
                }
            )
            .frame(width: 440, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var capturedImageContent: some View {
        VStack(spacing: 12) {
            if let image = capturedImage {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 440, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var ocrResultContent: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Recognised Text", systemImage: "text.viewfinder")
                    .font(.headline).foregroundStyle(.secondary)
                Spacer()
                if isProcessing { ProgressView().controlSize(.small) }
                Button("Crop Again") { showingCropView = true }
                    .buttonStyle(.bordered)
                    .disabled(capturedCGImage == nil)
                Button("Clear") { recognizedText = "" }
                    .buttonStyle(.bordered)
                    .disabled(recognizedText.isEmpty)
            }

            Text("Crop again to add more regions to the text below.")
                .font(.caption).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextEditor(text: $recognizedText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 160)

            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Pipeline picker card

    private var pipelinePickerCard: some View {
        VStack(spacing: 0) {
            LabeledContent("After Capture") {
                Picker("", selection: $selectedPostCapturePipelineID) {
                    Text("None").tag(nil as PersistentIdentifier?)
                    ForEach(postCapturePipelines) { p in
                        Text(p.name).tag(p.id as PersistentIdentifier?)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isRunningPostCapture || postCapturePipelines.isEmpty)
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

            Divider().padding(.leading, 12)
            HStack {
                Spacer()
                Button {
                    appState.inspectorDefaultScope = .postCapture
                    appState.inspectorVisible = true
                } label: {
                    Label("Manage Actions…", systemImage: "slider.horizontal.3")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Task bar

    @ViewBuilder
    private var acquireTaskBar: some View {
        if !recognizedText.isEmpty || (isProcessing && capturedCGImage != nil) {
            // OCR result state — Continue task bar
            HStack {
                Button("Cancel") {
                    captureVM.reset()
                    closeWizard()
                }
                .buttonStyle(.bordered)

                Button("Retake") {
                    capturedImage = nil
                    capturedCGImage = nil
                    recognizedText = ""
                    errorText = nil
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Continue") {
                    proceedToReview(text: recognizedText)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isProcessing
                    || isRunningPostCapture
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        } else if capturedImage != nil {
            // After capture — Crop & Recognise task bar
            HStack {
                Button("Cancel") {
                    captureVM.reset()
                    closeWizard()
                }
                .buttonStyle(.bordered)

                Button("Retake") {
                    capturedImage = nil
                    capturedCGImage = nil
                    recognizedText = ""
                    errorText = nil
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Crop & Recognise") {
                    showingCropView = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(capturedCGImage == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        } else {
            // Live preview — Capture task bar
            HStack {
                Button("Cancel") {
                    captureVM.reset()
                    closeWizard()
                }
                .buttonStyle(.bordered)

                Spacer()

                if isCapturing {
                    ProgressView().controlSize(.small)
                }

                Button("Capture") {
                    isCapturing = true
                    captureTrigger.capture()
                }
                .buttonStyle(.borderedProminent)
                .disabled(capturedImage != nil || isCapturing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Camera state

    @State private var availableCameras: [AVCaptureDevice] = []
    @State private var selectedCameraIndex = 0
    @State private var cameraPreviewRef: CameraPreviewNSView?

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
                        sourceText: text,
                        pipeline: pipeline,
                        onProgress: { [self] p in postCaptureProgress = p }
                    )
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
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        wizardStep = .review
                    }
                }
            }
        } else {
            reviewStepIndex = 1
            stepForward = true
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                wizardStep = .review
            }
        }
    }

    // MARK: - OCR

    private func processCroppedImage(_ cgImage: CGImage) async {
        guard !isProcessing else { return }
        isProcessing = true
        errorText = nil
        do {
            let text = try await VisionTextService.recognizeText(in: cgImage)
            if text.isEmpty {
                errorText = "No text detected in the cropped region."
            } else {
                recognizedText = recognizedText.isEmpty
                    ? text
                    : recognizedText + "\n\n--- Crop ---\n\n" + text
            }
        } catch {
            errorText = error.localizedDescription
        }
        isProcessing = false
    }
}

// MARK: - Live camera preview (NSViewRepresentable)

struct CameraPreviewView: NSViewRepresentable {
    let captureTrigger: CameraCaptureTrigger
    let onCapture: (NSImage) -> Void
    let onViewCreated: (CameraPreviewNSView) -> Void

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.onCapture = onCapture
        captureTrigger.view = view
        onViewCreated(view)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.onCapture = onCapture
        captureTrigger.view = nsView
    }
}

// MARK: - NSView camera implementation

class CameraPreviewNSView: NSView {
    var onCapture: ((NSImage) -> Void)?
    private(set) var availableCameras: [AVCaptureDevice] = []

    private var session: AVCaptureSession?
    private var output: AVCapturePhotoOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var currentInput: AVCaptureDeviceInput?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startSession() }
    }

    private func startSession() {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 13, *) { types.append(.continuityCamera) }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        availableCameras = discovery.devices

        guard let device = discovery.devices.first,
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        let session = AVCaptureSession()
        self.session = session
        session.addInput(input)
        currentInput = input

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
    }

    func switchCamera(to device: AVCaptureDevice) {
        guard let session = session,
              let newInput = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        if let old = currentInput { session.removeInput(old) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            currentInput = newInput
        }
        session.commitConfiguration()
    }

    func capturePhoto() {
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
        .frame(width: 520, height: 560)
}
