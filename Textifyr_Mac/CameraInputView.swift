import SwiftUI
import TextifyrModels
import AVFoundation
import AppKit
import TextifyrViewModels
import TextifyrServices

struct CameraInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isCapturing = false
    @State private var capturedImage: NSImage?
    @State private var isProcessing = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Camera Capture")
                .font(.title2).bold()
                .padding(.top, 24)

            if let image = capturedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 400, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 16) {
                    Button("Retake") { capturedImage = nil }
                        .buttonStyle(.bordered)

                    if isProcessing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Recognising text…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Use Photo") { processImage(image) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                CameraPreviewView(onCapture: { image in
                    capturedImage = image
                })
                .frame(width: 400, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Button("Cancel") {
                captureVM.reset()
                dismiss()
            }
            .buttonStyle(.bordered)
            .padding(.bottom, 28)
        }
        .frame(width: 480)
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { dismiss() }
        }
    }

    private func processImage(_ image: NSImage) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            errorText = "Could not process image."
            return
        }
        isProcessing = true
        errorText = nil
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        do {
            try pngData.write(to: url)
            Task {
                do {
                    let text = try await VisionTextService.recognizeText(in: url)
                    captureVM.saveTextCapture(text, captureMethod: .camera)
                } catch {
                    errorText = error.localizedDescription
                }
                isProcessing = false
            }
        } catch {
            errorText = error.localizedDescription
            isProcessing = false
        }
    }
}

// MARK: - Live camera preview

private struct CameraPreviewView: NSViewRepresentable {
    let onCapture: (NSImage) -> Void

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {}
}

private class CameraPreviewNSView: NSView {
    var onCapture: ((NSImage) -> Void)?

    private var session: AVCaptureSession?
    private var output: AVCapturePhotoOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureButton: NSButton?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startSession() }
    }

    private func startSession() {
        let session = AVCaptureSession()
        self.session = session
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
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
        self.previewLayer = layer

        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }

        let btn = NSButton(title: "Capture", target: self, action: #selector(capture))
        btn.bezelStyle = .rounded
        btn.frame = NSRect(x: (bounds.width - 80) / 2, y: 8, width: 80, height: 28)
        btn.autoresizingMask = [.minXMargin, .maxXMargin]
        addSubview(btn)
        captureButton = btn
    }

    @objc private func capture() {
        let settings = AVCapturePhotoSettings()
        output?.capturePhoto(with: settings, delegate: self)
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
