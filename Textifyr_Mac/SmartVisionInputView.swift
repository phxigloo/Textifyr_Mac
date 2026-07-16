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
    @Environment(\.wizardDismiss) private var wizardDismiss
    private func closeWizard() { wizardDismiss != nil ? wizardDismiss!() : dismiss() }
    @EnvironmentObject private var appState: AppState

    private enum WizardStep { case capture, review }
    @State private var wizardStep: WizardStep = .capture
    @State private var showDiscardConfirm = false

    // Capture
    @State private var captureSource: CaptureSourceType? = nil
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var showFileImporter = false
    @State private var capturedImage: CGImage? = nil
    @State private var showCropView = false
    @State private var capturedDisplays: [(name: String, image: CGImage)] = []
    @State private var showDisplayPicker = false
    @State private var displayCarouselIndex = 0
    @State private var showScreenCapturePrepare = false
    @State private var suppressScreenCapturePrepare = false
    private static let suppressPrepareKey = "suppressSmartVisionScreenCapturePrepare"

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
            ToolColumnHeader("Embed Image")
            stepContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Pre-load image passed from the Share Extension "Embed Image" path
            if let data = appState.pendingSharedImageData {
                appState.pendingSharedImageData = nil
                let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
                if let ci = CIImage(data: data, options: [.applyOrientationProperty: true]),
                   let cg = ciCtx.createCGImage(ci, from: ci.extent) {
                    capturedImage = cg
                    applyPictureProcessing(to: cg)
                    wizardStep = .review
                }
            }
        }
        .sheet(isPresented: $showCropView) {
            if let img = capturedImage {
                NavigationStack {
                    CroppableImageView(
                        image: img,
                        onCrop: { cropped in
                            showCropView = false
                            capturedImage = cropped
                            applyPictureProcessing(to: cropped)
                            wizardStep = .review
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
            if src == .screenCapture {
                captureSource = nil
                if UserDefaults.standard.bool(forKey: Self.suppressPrepareKey) {
                    Task { await captureScreen() }
                } else {
                    showScreenCapturePrepare = true
                }
            }
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
        .confirmationDialog("Discard this image?",
                            isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { cancelWizard() }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("The captured image will be lost.")
        }
        .onAppear {
            updateWizardBreadcrumb()
            appState.captureWizardActive = true
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
        wizardStep == .review || capturedImage != nil || processedImage != nil
    }

    /// Wizard step in the jump-bar (Phase 22.8): `Documents ▸ Document: <doc> ▸ Add Source ▸ Embed Image [▸ Review]`.
    private func updateWizardBreadcrumb() {
        let docTitle = captureVM.document.title
        var crumbs: [BreadcrumbCrumb] = [
            BreadcrumbCrumb("Documents", target: .documents),
            BreadcrumbCrumb("Document: \(docTitle.isEmpty ? "Document" : docTitle)", target: .documents),
            BreadcrumbCrumb("Add Source"),
            BreadcrumbCrumb("Embed Image"),
        ]
        if wizardStep == .review { crumbs.append(BreadcrumbCrumb("Review")) }
        appState.breadcrumb = crumbs
    }

    private func cancelWizard() {
        captureVM.reset()
        closeWizard()
    }

    // MARK: - Step dispatch

    @ViewBuilder
    private var stepContent: some View {
        switch wizardStep {
        case .capture: captureStep
        case .review:  reviewStep
        }
    }

    // MARK: - Step 1: Capture

    private var captureStep: some View {
        VStack(spacing: 0) {
            Group {
                if showScreenCapturePrepare {
                    screenCapturePrepareContent
                } else if showDisplayPicker {
                    inlineDisplayPicker
                } else {
                    sourceGridContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ToolColumnFooter {
                Button("Cancel") {
                    if showScreenCapturePrepare {
                        showScreenCapturePrepare = false
                    } else if showDisplayPicker {
                        showDisplayPicker = false
                        capturedDisplays = []
                        displayCarouselIndex = 0
                    } else {
                        cancelWizard()
                    }
                }
                .buttonStyle(.bordered)
                Spacer()
                captureStepTrailingButton
            }
        }
    }

    @ViewBuilder private var sourceGridContent: some View {
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

    @ViewBuilder private var screenCapturePrepareContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 48)).foregroundStyle(.tint)

            Text("Prepare Your Screen")
                .font(.title3.bold())

            Text("Arrange the windows you want to capture before proceeding. Textifyr is automatically excluded from the screenshot.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)

            Toggle("Don't show this again", isOn: $suppressScreenCapturePrepare)
                .toggleStyle(.checkbox)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    @ViewBuilder private var inlineDisplayPicker: some View {
        VStack(spacing: 12) {
            Text("Select Display")
                .font(.headline)

            if !capturedDisplays.isEmpty {
                Text(capturedDisplays[displayCarouselIndex].name)
                    .font(.subheadline).foregroundStyle(.secondary)

                HStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            displayCarouselIndex = max(displayCarouselIndex - 1, 0)
                        }
                    } label: {
                        Image(systemName: "chevron.left").font(.title2.bold())
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(displayCarouselIndex == 0)
                    .opacity(displayCarouselIndex == 0 ? 0.3 : 1)

                    let img = capturedDisplays[displayCarouselIndex].image
                    Image(nsImage: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)))
                        .resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4), lineWidth: 1))
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                        .padding(.horizontal, 8)
                        .id(displayCarouselIndex)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            displayCarouselIndex = min(displayCarouselIndex + 1, capturedDisplays.count - 1)
                        }
                    } label: {
                        Image(systemName: "chevron.right").font(.title2.bold())
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(displayCarouselIndex >= capturedDisplays.count - 1)
                    .opacity(displayCarouselIndex >= capturedDisplays.count - 1 ? 0.3 : 1)
                }

                HStack(spacing: 8) {
                    ForEach(capturedDisplays.indices, id: \.self) { i in
                        Circle()
                            .fill(i == displayCarouselIndex ? Color.accentColor : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                            .onTapGesture { withAnimation { displayCarouselIndex = i } }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal)
    }

    @ViewBuilder private var captureStepTrailingButton: some View {
        if showScreenCapturePrepare {
            Button("Capture Now") {
                if suppressScreenCapturePrepare {
                    UserDefaults.standard.set(true, forKey: Self.suppressPrepareKey)
                }
                showScreenCapturePrepare = false
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    await captureScreen()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        } else if showDisplayPicker {
            HStack(spacing: 12) {
                Button("Recapture") {
                    showDisplayPicker = false
                    capturedDisplays = []
                    displayCarouselIndex = 0
                    Task { await captureScreen() }
                }
                .buttonStyle(.bordered)
                Button {
                    let selected = capturedDisplays[displayCarouselIndex].image
                    showDisplayPicker = false
                    capturedDisplays = []
                    displayCarouselIndex = 0
                    capturedImage = selected
                    showCropView = true
                } label: {
                    Label("Use This Display", systemImage: "crop")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        // Source grid: no trailing button (Cancel is the only action)
    }

    // MARK: - Step 2: Review & Describe (image preview + colours/category + caption)

    private var reviewStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    if let img = processedImage {
                        Image(nsImage: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                            .padding(.horizontal)
                    } else {
                        ProgressView("Processing image…").frame(height: 100)
                    }

                    // Appearance + category
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

                    Divider().padding(.horizontal)

                    // Caption / description
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description")
                            .font(.caption2).textCase(.uppercase).foregroundStyle(.tertiary)
                        Text("Optional text that appears below the image in the output.")
                            .font(.caption).foregroundStyle(.secondary)

                        TextEditor(text: $annotationText)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .frame(minHeight: 80, maxHeight: 160)

                        Button {
                            withAnimation { showAIPrompt.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showAIPrompt ? "chevron.down" : "chevron.right").font(.caption2)
                                Image(systemName: "wand.and.sparkles").font(.caption)
                                Text("Generate text with AI").font(.caption)
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
                                if isGeneratingAI { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                    .padding(.horizontal)

                    if let error = errorText {
                        Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
                    }
                }
                .padding(.vertical, 12)
            }

            ToolColumnFooter {
                Button("Cancel") { cancelWizard() }
                    .buttonStyle(.bordered)
                Button("Retake") {
                    capturedImage = nil
                    processedImage = nil
                    wizardStep = .capture
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Insert") { insertPicture() }
                    .buttonStyle(.borderedProminent)
                    .disabled(processedImage == nil)
            }
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
                .font(.system(size: 28))
                .foregroundStyle(dimmed ? Color.secondary : Color.accentColor)
            Text(label)
                .font(.caption)
                .multilineTextAlignment(.center)
            
                .lineLimit(2)
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Capture actions

    private func captureScreen() async {
        do {
            let results = try await ScreenCaptureService.captureAllDisplays()
            captureSource = nil
            if results.count == 1, let first = results.first {
                capturedImage = first.image
                showCropView = true
            } else if results.count > 1 {
                capturedDisplays = results
                showDisplayPicker = true
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

// MARK: - Edit mode view

struct SmartVisionEditView: View {
    let session: SourceSession
    let context: ModelContext
    let onDismiss: () -> Void

    @EnvironmentObject private var appState: AppState

    @State private var capturedImage: CGImage? = nil
    @State private var processingMode: PictureProcessingMode = .none
    @State private var useAppColors = true
    @State private var processedImage: CGImage? = nil
    @State private var annotationText = ""
    @State private var showAIPrompt = false
    @State private var aiPromptText = ""
    @State private var isGeneratingAI = false
    @StateObject private var aiService = SessionAIService()
    @State private var errorText: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            ToolColumnHeader("Edit Image")
            reviewContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await loadExistingImage() }
        .alert("Error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    // MARK: - Review & Describe (single screen — preview + colours/category + caption)

    private var reviewContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    if let img = processedImage {
                        Image(nsImage: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 200)
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

                    Divider().padding(.horizontal)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description")
                            .font(.caption2).textCase(.uppercase).foregroundStyle(.tertiary)
                        Text("Optional text that appears below the image in the output.")
                            .font(.caption).foregroundStyle(.secondary)

                        TextEditor(text: $annotationText)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .frame(minHeight: 80, maxHeight: 160)

                        Button {
                            withAnimation { showAIPrompt.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showAIPrompt ? "chevron.down" : "chevron.right").font(.caption2)
                                Image(systemName: "wand.and.sparkles").font(.caption)
                                Text("Generate text with AI").font(.caption)
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
                                if isGeneratingAI { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                    .padding(.horizontal)

                    if let error = errorText {
                        Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
                    }
                }
                .padding(.vertical, 12)
            }

            ToolColumnFooter {
                Button("Cancel", action: onDismiss).buttonStyle(.bordered)
                Spacer()
                Button("Save") { savePicture() }
                    .buttonStyle(.borderedProminent)
                    .disabled(processedImage == nil)
            }
        }
    }

    // MARK: - Load existing image

    private func loadExistingImage() async {
        annotationText = session.rawText
        guard let pngData = session.rawRTFData,
              let ns = NSImage(data: pngData),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorText = "Could not load the existing image."
            return
        }
        capturedImage = cg
        applyPictureProcessing(to: cg)
    }

    // MARK: - Picture processing

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

    // MARK: - Save

    private func savePicture() {
        guard let img = processedImage else { return }
        let bmpRep = NSBitmapImageRep(cgImage: img)
        guard let pngData = bmpRep.representation(using: .png, properties: [:]) else {
            errorText = "Could not encode image as PNG."
            return
        }
        session.rawText    = annotationText
        session.rawRTFData = pngData
        try? context.save()
        onDismiss()
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
    @StateObject private var captureTrigger = CameraCaptureTrigger()
    @State private var isCapturing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "camera.fill").foregroundStyle(.tint)
                Text("Camera").font(.title2).bold()
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)
            Divider()
            CameraPreviewView(
                captureTrigger: captureTrigger,
                onCapture: { image in
                    isCapturing = false
                    if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        onCapture(cg)
                    }
                },
                onCaptureError: {
                    isCapturing = false
                },
                onViewCreated: { _ in }
            )
            .frame(minHeight: 340)
            Divider()
            HStack {
                Button("Cancel", action: onCancel).buttonStyle(.bordered)
                Spacer()
                if isCapturing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Capture") {
                        isCapturing = true
                        captureTrigger.capture()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
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
