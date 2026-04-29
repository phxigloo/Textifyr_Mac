import SwiftUI
import AppKit
import AVFoundation
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

struct CameraInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var capturedImage: NSImage?
    @State private var capturedCGImage: CGImage?
    @State private var recognizedText = ""
    @State private var isProcessing = false
    @State private var showingCropView = false
    @State private var errorText: String?

    var body: some View {
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
        .frame(minWidth: 520)
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
            if phase == .done { dismiss() }
        }
        .onAppear  { appState.setCameraInUse(true) }
        .onDisappear { appState.setCameraInUse(false) }
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

        Button("Cancel") { captureVM.reset(); dismiss() }
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

            Button("Crop & Recognise") { showingCropView = true }
                .buttonStyle(.borderedProminent)
                .disabled(capturedCGImage == nil)
        }

        if let error = errorText {
            Text(error).font(.caption).foregroundStyle(.red)
        }

        Button("Cancel") { captureVM.reset(); dismiss() }
            .buttonStyle(.bordered).padding(.bottom, 28)
    }

    // MARK: - Review

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

            HStack {
                Button("Cancel") { captureVM.reset(); dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button("Use Text") {
                    captureVM.saveTextCapture(recognizedText, captureMethod: .camera)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
            }
            .padding([.horizontal, .bottom])
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
