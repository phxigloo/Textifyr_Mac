import SwiftUI
import PhotosUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import AppKit
import TextifyrModels
import TextifyrViewModels
import TextifyrServices
import SwiftData

// MARK: - Picture processing mode

enum PictureProcessingMode: String, CaseIterable, Identifiable {
    case none
    case formula
    case chemical
    case handwriting
    case diagram

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:        return "None"
        case .formula:     return "Formula / Equation"
        case .chemical:    return "Chemical Structure"
        case .handwriting: return "Handwriting / Sketch"
        case .diagram:     return "Diagram / Chart"
        }
    }

    var pictureCaption: String {
        switch self {
        case .none:        return "Embedded Picture"
        case .formula:     return "Formula / Equation"
        case .chemical:    return "Chemical Structure"
        case .handwriting: return "Handwriting / Sketch"
        case .diagram:     return "Diagram / Chart"
        }
    }
}

// MARK: - Main view

struct SmartVisionInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    private enum WizardStep { case capture, process, annotate }
    @State private var wizardStep: WizardStep = .capture

    // Capture
    @State private var captureSource: CaptureSourceType? = nil
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var showFileImporter = false
    @State private var capturedImage: CGImage? = nil
    @State private var showCropView = false

    // Process
    @State private var processingMode: PictureProcessingMode = .none
    @State private var useAppColors = true
    @State private var processedImage: CGImage? = nil

    // Annotate
    @State private var annotationText = ""
    @State private var showAIPrompt = false
    @State private var aiPromptText = ""
    @State private var isGeneratingAI = false
    @StateObject private var aiService = SessionAIService()

    @State private var errorText: String? = nil

    enum CaptureSourceType { case camera, photoLibrary, screenCapture, imageFile }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepContent
        }
        .frame(width: 600)
        .sheet(isPresented: $showCropView) {
            if let img = capturedImage {
                NavigationStack {
                    CroppableImageView(
                        image: img,
                        onCrop: { cropped in
                            showCropView = false
                            capturedImage = cropped
                            applyPictureProcessing(to: cropped)
                            wizardStep = .process
                        },
                        onCancel: {
                            showCropView = false
                            capturedImage = nil
                        }
                    )
                    .navigationTitle("Crop Image")
                }
                .frame(minWidth: 600, minHeight: 500)
            }
        }
        .sheet(isPresented: Binding(
            get: { captureSource == .camera },
            set: { if !$0 { captureSource = nil } }
        )) {
            SmartVisionCameraSheet { image in
                captureSource = nil
                capturedImage = image
                showCropView = true
            } onCancel: {
                captureSource = nil
            }
        }
        .onChange(of: captureSource) { _, src in
            if src == .screenCapture { Task { await captureScreen() } }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image, .png, .jpeg, .tiff, .heic, .bmp, .gif, .webP],
            allowsMultipleSelection: false
        ) { result in
            if let url = try? result.get().first { Task { await loadImageFile(url) } }
        }
        .alert("Error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { errorText = nil }
        } message: { Text(errorText ?? "") }
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { dismiss() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "photo.badge.plus").foregroundStyle(Color.accentColor)
            Text("Insert Image").font(.title2).bold()
            Spacer()
            stepIndicator
            Spacer()
            Button("Cancel") { captureVM.reset(); dismiss() }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(stepIndex >= i ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: stepIndex == i ? 10 : 7, height: stepIndex == i ? 10 : 7)
                    .animation(.easeInOut(duration: 0.2), value: wizardStep)
                if i < 2 {
                    Rectangle()
                        .fill(stepIndex > i ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 36, height: 2)
                }
            }
        }
    }

    private var stepIndex: Int {
        switch wizardStep {
        case .capture: return 0
        case .process: return 1
        case .annotate: return 2
        }
    }

    // MARK: - Step dispatch

    @ViewBuilder
    private var stepContent: some View {
        switch wizardStep {
        case .capture:  captureStep
        case .process:  processStep
        case .annotate: annotateStep
        }
    }

    // MARK: - Step 1: Capture

    private var captureStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Step 1 — Capture").font(.headline)
                    Text("Choose an image source. You will be able to crop after capture.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                    sourceButton("Camera", icon: "camera.fill", disabled: !appState.canUseCamera) {
                        captureSource = .camera
                    }
                    PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                        sourceButtonLabel("Photo Library", icon: "photo.on.rectangle")
                    }.buttonStyle(.plain)

                    sourceButton("Screen Capture", icon: "rectangle.dashed") {
                        captureSource = .screenCapture
                    }
                    sourceButton("Image File", icon: "photo") {
                        showFileImporter = true
                    }
                }

                if let error = errorText {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Step 2: Process

    private var processStep: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Step 2 — Process").font(.headline)
                Text("Optionally adapt colours and choose a category label for the image.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            if let img = processedImage {
                Image(nsImage: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    .padding(.horizontal)
            } else {
                ProgressView("Processing image…").frame(height: 100)
            }

            VStack(spacing: 10) {
                Toggle("Adapt colours to app appearance (grayscale + theme colours)", isOn: $useAppColors)
                    .font(.caption)
                    .onChange(of: useAppColors) { _, _ in
                        if let src = capturedImage { applyPictureProcessing(to: src) }
                    }

                HStack {
                    Text("Category:").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $processingMode) {
                        ForEach(PictureProcessingMode.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                    Spacer()
                }
            }
            .padding(.horizontal)

            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            HStack {
                Button("← Back") {
                    capturedImage = nil
                    processedImage = nil
                    wizardStep = .capture
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Next →") { wizardStep = .annotate }
                    .buttonStyle(.borderedProminent)
                    .disabled(processedImage == nil)
            }
            .padding(.horizontal)
            .padding(.bottom)
            .padding(.top, 8)
        }
        .padding(.top, 8)
    }

    // MARK: - Step 3: Annotate

    private var annotateStep: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Step 3 — Description").font(.headline)
                Text("Optionally add text that will appear below the image in the output.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            if let img = processedImage {
                Image(nsImage: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    .padding(.horizontal)
            }

            TextEditor(text: $annotationText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
                .frame(minHeight: 80, maxHeight: 160)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation { showAIPrompt.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showAIPrompt ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Image(systemName: "wand.and.sparkles")
                            .font(.caption)
                        Text("Generate text with AI")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if showAIPrompt {
                    HStack(spacing: 8) {
                        TextField("Describe what text to generate…", text: $aiPromptText)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        Button("Generate") { Task { await generateAI() } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(aiPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGeneratingAI)
                        if isGeneratingAI {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
            .padding(.horizontal)

            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            HStack {
                Button("← Back") { wizardStep = .process }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Cancel") { captureVM.reset(); dismiss() }.buttonStyle(.bordered)
                Button("Insert") { insertPicture() }
                    .buttonStyle(.borderedProminent)
                    .disabled(processedImage == nil)
            }
            .padding(.horizontal)
            .padding(.bottom)
            .padding(.top, 8)
        }
        .padding(.top, 8)
    }

    // MARK: - Source button helpers

    @ViewBuilder
    private func sourceButton(_ label: String, icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            sourceButtonLabel(label, icon: icon, dimmed: disabled)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(disabled ? "Camera is already in use in another window" : "")
    }

    func sourceButtonLabel(_ label: String, icon: String, dimmed: Bool = false) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(dimmed ? Color.secondary : Color.accentColor)
            Text(label)
                .font(.caption)
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Capture actions

    private func captureScreen() async {
        do {
            let results = try await ScreenCaptureService.captureAllDisplays()
            captureSource = nil
            if let first = results.first {
                capturedImage = first.image
                showCropView = true
            }
        } catch {
            captureSource = nil
            errorText = "Screen capture failed: \(error.localizedDescription)"
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let ns = NSImage(data: data),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorText = "Could not load the selected photo."
            return
        }
        capturedImage = cg
        showCropView = true
    }

    private func loadImageFile(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let ns = NSImage(data: data),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorText = "Could not load image file."
            return
        }
        capturedImage = cg
        showCropView = true
    }

    // MARK: - Picture pipeline

    private func applyPictureProcessing(to image: CGImage) {
        processedImage = nil
        guard useAppColors else {
            DispatchQueue.global(qos: .userInitiated).async {
                let scaled = SmartVisionImageProcessor.scale(image, maxWidth: 1200)
                DispatchQueue.main.async { self.processedImage = scaled }
            }
            return
        }
        var fgColor = CIColor(red: 0, green: 0, blue: 0)
        var bgColor = CIColor(red: 1, green: 1, blue: 1)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            var fgR: CGFloat = 0, fgG: CGFloat = 0, fgB: CGFloat = 0
            var bgR: CGFloat = 0, bgG: CGFloat = 0, bgB: CGFloat = 0
            (NSColor.labelColor.usingColorSpace(.genericRGB) ?? .black)
                .getRed(&fgR, green: &fgG, blue: &fgB, alpha: nil)
            (NSColor.textBackgroundColor.usingColorSpace(.genericRGB) ?? .white)
                .getRed(&bgR, green: &bgG, blue: &bgB, alpha: nil)
            fgColor = CIColor(red: fgR, green: fgG, blue: fgB)
            bgColor = CIColor(red: bgR, green: bgG, blue: bgB)
        }
        let fg = fgColor, bg = bgColor
        DispatchQueue.global(qos: .userInitiated).async {
            let recolored = SmartVisionImageProcessor.recolorWith(image, fg: fg, bg: bg) ?? image
            let scaled = SmartVisionImageProcessor.scale(recolored, maxWidth: 1200)
            DispatchQueue.main.async { self.processedImage = scaled }
        }
    }

    private func insertPicture() {
        guard let img = processedImage else { return }
        let bmpRep = NSBitmapImageRep(cgImage: img)
        guard let pngData = bmpRep.representation(using: .png, properties: [:]) else {
            errorText = "Could not encode image as PNG."
            return
        }
        captureVM.savePictureCapture(pngData: pngData, annotation: annotationText)
    }

    // MARK: - AI generation

    private func generateAI() async {
        let prompt = aiPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isGeneratingAI = true
        do {
            let stream = try await aiService.send(prompt)
            var result = ""
            for await chunk in stream { result += chunk }
            if !result.isEmpty { annotationText = result }
        } catch {
            errorText = "AI generation failed: \(error.localizedDescription)"
        }
        isGeneratingAI = false
    }
}

// MARK: - Camera sheet

private struct SmartVisionCameraSheet: View {
    let onCapture: (CGImage) -> Void
    let onCancel: () -> Void
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Camera").font(.title2).bold()
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.borderless)
            }.padding(20)
            Divider()
            CameraPreviewView { image in
                if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    onCapture(cg)
                }
            }
            .frame(minHeight: 340)
        }
        .frame(width: 520)
        .onAppear    { appState.setCameraInUse(true)  }
        .onDisappear { appState.setCameraInUse(false) }
    }
}

// MARK: - Image processor

enum SmartVisionImageProcessor {

    /// Converts the image to grayscale then maps dark pixels → fg, light pixels → bg.
    /// fg/bg must be resolved on the main thread by the caller before dispatching to background.
    static func recolorWith(_ cgImage: CGImage, fg: CIColor, bg: CIColor) -> CGImage? {
        let ci = CIImage(cgImage: cgImage)

        guard let mono = CIFilter(name: "CIPhotoEffectMono",
                                   parameters: [kCIInputImageKey: ci]),
              let monoOut = mono.outputImage else { return nil }

        guard let fc = CIFilter(name: "CIFalseColor", parameters: [
            kCIInputImageKey: monoOut,
            "inputColor0": fg,  // dark → foreground
            "inputColor1": bg   // light → background
        ]), let out = fc.outputImage else { return nil }

        // Normalize extent to origin (0,0) — CIFalseColor can shift the origin
        let norm = out.transformed(by: CGAffineTransform(translationX: -out.extent.origin.x,
                                                          y: -out.extent.origin.y))
        // Pin to device RGB so downstream callers get a well-known color space
        let ctx = CIContext(options: [.outputColorSpace: CGColorSpaceCreateDeviceRGB()])
        return ctx.createCGImage(norm, from: norm.extent)
    }

    /// Scales an image down so its width does not exceed `maxWidth` pixels.
    static func scale(_ cgImage: CGImage, maxWidth: Int) -> CGImage {
        let w = cgImage.width
        let h = cgImage.height
        guard w > maxWidth else { return cgImage }
        let scale = CGFloat(maxWidth) / CGFloat(w)
        let newW = maxWidth
        let newH = Int(CGFloat(h) * scale)
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cgImage }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? cgImage
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let captureVM = previewCaptureVM(in: c)
    return SmartVisionInputView(captureVM: captureVM)
        .modelContainer(c)
        .environmentObject(AppState())
        .frame(width: 600, height: 560)
}
