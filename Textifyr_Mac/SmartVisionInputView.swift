import SwiftUI
import PhotosUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import AppKit
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

// MARK: - Mode definitions

enum SmartVisionMode: String, CaseIterable, Identifiable {

    // ── Text extraction (OCR) ──────────────────────────────────────────────
    case general
    case receipt
    case code
    case businessCard

    // ── Picture insertion (embed image in RTF) ────────────────────────────
    case formula
    case chemical
    case handwriting
    case diagram
    case anyPicture

    var id: String { rawValue }

    var isPicture: Bool {
        switch self {
        case .formula, .chemical, .handwriting, .diagram, .anyPicture: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .general:      return "General Text"
        case .receipt:      return "Receipt / Invoice"
        case .code:         return "Code Screenshot"
        case .businessCard: return "Business Card"
        case .formula:      return "Formula / Equation"
        case .chemical:     return "Chemical Structure"
        case .handwriting:  return "Handwriting / Sketch"
        case .diagram:      return "Diagram / Chart"
        case .anyPicture:   return "Any Picture"
        }
    }

    var icon: String {
        switch self {
        case .general:      return "text.viewfinder"
        case .receipt:      return "receipt"
        case .code:         return "chevron.left.forwardslash.chevron.right"
        case .businessCard: return "person.text.rectangle"
        case .formula:      return "function"
        case .chemical:     return "atom"
        case .handwriting:  return "scribble"
        case .diagram:      return "chart.bar.doc.horizontal"
        case .anyPicture:   return "photo"
        }
    }

    var infoNote: String {
        switch self {
        case .general:
            return "Extracts printed text from images. Works best with clear, well-lit printed text on a plain background."
        case .receipt:
            return "Reads prices, dates, and items from receipts. Printed receipts work well; handwritten amounts may be misread."
        case .code:
            return "Captures source code from screenshots. Indentation and special characters are preserved where possible."
        case .businessCard:
            return "Extracts contact details (name, phone, email, address) from standard printed business cards."
        case .formula:
            return "Embeds a photo of the formula directly into the output as a picture. The formula is not converted to text — it is stored as an image."
        case .chemical:
            return "Embeds a photo of a chemical structure diagram as a picture in the output. Bond lines and ring structures are preserved exactly as photographed."
        case .handwriting:
            return "Embeds a photo of handwritten notes or a sketch as a picture. The handwriting is not converted to typed text."
        case .diagram:
            return "Embeds a photo of a diagram, chart, flowchart, or mind map as a picture in the output."
        case .anyPicture:
            return "Embeds any image directly into the output as a picture. Use this when you want the image itself, not the text inside it."
        }
    }

    /// Preset AI prompt for OCR enhancement; empty for picture modes.
    var aiPrompt: String {
        switch self {
        case .receipt:
            return "The following text was extracted from a receipt or invoice. Organise it into a clean summary: merchant name, date, individual items with prices, subtotal, tax, and total."
        case .code:
            return "The following text was extracted from a screenshot of source code. Clean up any OCR errors (misread characters, broken indentation) and present the code clearly. Preserve the programming language if identifiable."
        case .businessCard:
            return "The following text was extracted from a business card. Organise the information into clearly labelled fields: Name, Title, Company, Phone, Email, Website, Address."
        default:
            return ""
        }
    }

    /// Caption inserted above the embedded image in the RTF output.
    var pictureCaption: String {
        switch self {
        case .formula:      return "Formula / Equation"
        case .chemical:     return "Chemical Structure"
        case .handwriting:  return "Handwriting / Sketch"
        case .diagram:      return "Diagram / Chart"
        case .anyPicture:   return "Embedded Picture"
        default:            return "Picture"
        }
    }
}

// MARK: - Main view

struct SmartVisionInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: AppState

    @State private var mode: SmartVisionMode = .general
    @State private var showInfo = false

    // Capture
    @State private var captureSource: CaptureSourceType? = nil
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var showFileImporter = false
    @State private var capturedImage: CGImage? = nil
    @State private var showCropView = false

    // OCR flow
    @State private var isProcessing = false
    @State private var isEnhancing = false
    @State private var ocrText = ""
    @StateObject private var aiService = SessionAIService()

    // Picture flow
    @State private var useAppColors = true
    @State private var processedImage: CGImage? = nil

    @State private var errorText: String? = nil

    enum CaptureSourceType { case camera, photoLibrary, screenCapture, imageFile }

    private var inModeSelect: Bool { capturedImage == nil }
    private var hasOCRText: Bool { !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if inModeSelect {
                modeSelectContent
            } else if mode.isPicture {
                pictureReviewContent
            } else {
                ocrReviewContent
            }
        }
        .frame(width: 600)
        // Crop sheet
        .sheet(isPresented: $showCropView) {
            if let img = capturedImage {
                NavigationStack {
                    CroppableImageView(
                        image: img,
                        onCrop: { cropped in
                            showCropView = false
                            if mode.isPicture {
                                applyPictureProcessing(to: cropped)
                            } else {
                                Task { await runOCR(on: cropped) }
                            }
                        },
                        onCancel: {
                            showCropView = false
                            capturedImage = nil
                        }
                    )
                    .navigationTitle("Crop — \(mode.displayName)")
                }
                .frame(minWidth: 600, minHeight: 500)
            }
        }
        // Info sheet
        .sheet(isPresented: $showInfo) { infoSheet }
        // Camera sheet
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
        // Screen capture
        .onChange(of: captureSource) { _, src in
            if src == .screenCapture { Task { await captureScreen() } }
        }
        // Photo picker
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        // File importer
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
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            Text("Smart Vision").font(.title2).bold()
            Button { showInfo = true } label: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("About Smart Vision")
            Spacer()
            Button("Cancel") { captureVM.reset(); dismiss() }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Mode selection

    private var modeSelectContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Extract text section
                modeSection(
                    title: "Extract Text (OCR)",
                    subtitle: "Recognises and extracts text from the image",
                    modes: [.general, .receipt, .code, .businessCard]
                )

                Divider()

                // Insert picture section
                modeSection(
                    title: "Insert as Picture",
                    subtitle: "Embeds the image directly into the output — content is not converted to text",
                    modes: [.formula, .chemical, .handwriting, .diagram, .anyPicture]
                )

                // Selected mode note
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: mode.isPicture ? "photo.badge.exclamationmark" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(mode.isPicture ? Color.blue : Color.orange)
                    Text(mode.infoNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(
                    (mode.isPicture ? Color.blue : Color.orange).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .padding(.horizontal, 4)

                Divider()

                // Image source buttons
                VStack(spacing: 10) {
                    Text("Choose image source")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

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
                }
            }
            .padding(20)
        }
    }

    private func modeSection(title: String, subtitle: String, modes: [SmartVisionMode]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 8) {
                ForEach(modes) { m in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { mode = m }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: m.icon)
                                .font(.system(size: 22))
                                .foregroundStyle(mode == m ? Color.accentColor : Color.secondary)
                            Text(m.displayName)
                                .font(.caption2)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .foregroundStyle(mode == m ? Color.primary : Color.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            mode == m
                                ? Color.accentColor.opacity(0.12)
                                : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(mode == m ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - OCR review

    private var ocrReviewContent: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Extracted Text", systemImage: "text.viewfinder")
                    .font(.headline).foregroundStyle(.secondary)
                Spacer()
                if isProcessing || isEnhancing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(isEnhancing ? "AI enhancing…" : "Recognising…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !isProcessing {
                    Button("Re-crop") { showCropView = true }.buttonStyle(.bordered)
                    Button("New Image") { resetCapture() }.buttonStyle(.bordered)
                }
                if !mode.aiPrompt.isEmpty && hasOCRText && !isEnhancing {
                    Button("Enhance with AI") { Task { await enhance() } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }.padding(.horizontal)

            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            TextEditor(text: $ocrText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
                .frame(minHeight: 160)

            HStack {
                Button("Cancel") { captureVM.reset(); dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button("Use as Source") {
                    captureVM.saveTextCapture(ocrText, captureMethod: .smartVision)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasOCRText)
            }.padding([.horizontal, .bottom])
        }.padding(.top, 8)
    }

    // MARK: - Picture review

    private var pictureReviewContent: some View {
        VStack(spacing: 12) {
            // Warning banner
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This is a picture, not text")
                        .font(.subheadline).bold()
                    Text("The image will be embedded in the RTF output. It cannot be edited as text, searched, or processed by AI. To extract text instead, go back and choose an OCR mode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)

            // App colour toggle
            Toggle("Adapt colours to app appearance (converts to grayscale + app foreground/background)", isOn: $useAppColors)
                .font(.caption)
                .padding(.horizontal)
                .onChange(of: useAppColors) { _, _ in
                    if let src = capturedImage { applyPictureProcessing(to: src) }
                }

            // Image preview
            if let img = processedImage {
                Image(nsImage: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    .padding(.horizontal)
            } else {
                ProgressView("Processing image…").frame(height: 120)
            }

            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            HStack {
                Button("Re-crop") { showCropView = true }.buttonStyle(.bordered)
                Button("New Image") { resetCapture() }.buttonStyle(.bordered)
                Spacer()
                Button("Cancel") { captureVM.reset(); dismiss() }.buttonStyle(.bordered)
                Button("Insert as Picture") { insertPicture() }
                    .buttonStyle(.borderedProminent)
                    .disabled(processedImage == nil)
            }.padding([.horizontal, .bottom])
        }.padding(.top, 8)
    }

    // MARK: - Info sheet

    private var infoSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text("About Smart Vision").font(.title3).bold()
                Spacer()
                Button("Done") { showInfo = false }.buttonStyle(.borderedProminent)
            }.padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Smart Vision captures an image from any source and either extracts text using OCR, or embeds the image directly into your output.")
                        .font(.body)

                    // OCR accuracy warning
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OCR Accuracy Warning").font(.subheadline).bold()
                            Text("OCR (text recognition) is not perfect. It works best with clear, well-lit, printed text on a plain background. Blurry or angled images produce more errors. Always review the extracted text before using it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                    // Picture warning
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Picture Modes").font(.subheadline).bold()
                            Text("Picture modes embed the image directly into the RTF output — they do not convert the content to text. The picture looks correct but cannot be searched, edited as text, or processed by AI. This is the recommended approach for formulas, chemical structures, and diagrams where OCR produces unreliable results.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                    Text("Modes").font(.headline)
                    ForEach(SmartVisionMode.allCases) { m in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: m.icon)
                                .foregroundStyle(m.isPicture ? Color.blue : Color.accentColor)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(m.displayName).font(.subheadline).bold()
                                    if m.isPicture {
                                        Text("PICTURE").font(.caption2).bold()
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.15), in: Capsule())
                                            .foregroundStyle(.blue)
                                    } else if !m.aiPrompt.isEmpty {
                                        Text("AI").font(.caption2).bold()
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(Color.purple.opacity(0.15), in: Capsule())
                                            .foregroundStyle(.purple)
                                    }
                                }
                                Text(m.infoNote).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }

                    Text("Tips for better results").font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        tipRow("Hold the camera steady and perpendicular to the subject")
                        tipRow("Ensure good, even lighting with no harsh shadows")
                        tipRow("Use Crop to focus on just the area you need")
                        tipRow("For formulas and structures, photograph as close and straight-on as possible")
                        tipRow("\"Adapt colours\" converts the image to match light or dark mode — turn it off for colour diagrams")
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 500, height: 580)
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            Text(text).font(.caption)
        }
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

    // MARK: - OCR pipeline

    private func runOCR(on image: CGImage) async {
        isProcessing = true
        ocrText = ""
        do {
            ocrText = try await VisionTextService.recognizeText(in: image)
            if ocrText.isEmpty { errorText = "No text detected. Try cropping a clearer region." }
        } catch {
            errorText = error.localizedDescription
        }
        isProcessing = false
    }

    private func enhance() async {
        guard !mode.aiPrompt.isEmpty, hasOCRText else { return }
        isEnhancing = true
        do {
            let prompt = mode.aiPrompt + "\n\n---\n\n" + ocrText
            let stream = try await aiService.send(prompt)
            var result = ""
            for await chunk in stream { result += chunk }
            if !result.isEmpty { ocrText = result }
        } catch {
            errorText = "AI enhancement failed: \(error.localizedDescription)"
        }
        isEnhancing = false
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
        // Resolve NSColor values on the main thread before dispatching to background
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
        let plain = "[\(mode.pictureCaption) — embedded as picture]"
        captureVM.saveRTFCapture(rtfData: pngData, plainText: plain)
    }

    private func resetCapture() {
        capturedImage = nil
        processedImage = nil
        ocrText = ""
        errorText = nil
        captureSource = nil
        photoItem = nil
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
        .onAppear   { appState.setCameraInUse(true)  }
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
