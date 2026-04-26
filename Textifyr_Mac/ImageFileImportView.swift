import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

struct ImageFileImportView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var loadedImages: [CGImage] = []
    @State private var recognizedText = ""
    @State private var isLoadingImages = false
    @State private var isProcessing = false
    @State private var showFileImporter = false
    @State private var showingCropView = false
    @State private var cropImageIndex = 0
    @State private var errorText: String?

    private static let imageTypes: [UTType] = [.image, .png, .jpeg, .tiff, .bmp, .heic, .heif, .gif, .webP]

    var body: some View {
        VStack(spacing: 20) {
            Text("Import Image")
                .font(.title2).bold()
                .padding(.top, 24)

            if loadedImages.isEmpty && !isLoadingImages {
                selectionContent
            } else if isLoadingImages {
                loadingContent
            } else {
                reviewContent
            }
        }
        .frame(width: 560)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.imageTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): Task { await loadImageFiles(urls) }
            case .failure(let error): errorText = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingCropView) {
            if cropImageIndex < loadedImages.count {
                NavigationStack {
                    CroppableImageView(
                        image: loadedImages[cropImageIndex],
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
        .alert("Image Error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { errorText = nil }
        } message: { Text(errorText ?? "") }
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { dismiss() }
        }
    }

    // MARK: - Selection

    @ViewBuilder private var selectionContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.image")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("Open image files to extract text using OCR.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Supported: PNG, JPEG, TIFF, HEIC, BMP, GIF, WebP")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if let error = errorText { errorLabel(error) }

            Button("Choose Image…") { showFileImporter = true }
                .buttonStyle(.borderedProminent)

            Button("Cancel") { captureVM.reset(); dismiss() }
                .buttonStyle(.bordered)
                .padding(.bottom, 28)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Loading

    @ViewBuilder private var loadingContent: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Loading images…").font(.headline)
        }
        .frame(height: 200)
    }

    // MARK: - Review (crop + recognized text)

    @ViewBuilder private var reviewContent: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Recognised Text", systemImage: "text.viewfinder")
                    .font(.headline).foregroundStyle(.secondary)

                Spacer()

                if isProcessing { ProgressView().controlSize(.small) }

                if loadedImages.count > 1 {
                    Menu("Crop Image") {
                        ForEach(0..<loadedImages.count, id: \.self) { i in
                            Button("Image \(i + 1)") { cropImageIndex = i; showingCropView = true }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                } else {
                    Button("Crop") { cropImageIndex = 0; showingCropView = true }
                        .buttonStyle(.bordered)
                }

                Button("Clear") { recognizedText = "" }
                    .buttonStyle(.bordered)
                    .disabled(recognizedText.isEmpty)

                Button("Open More") { loadedImages = []; recognizedText = ""; showFileImporter = true }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            Text("Crop to select regions for OCR. Each crop appends to the text below.")
                .font(.caption).foregroundStyle(.tertiary).padding(.horizontal)

            if recognizedText.isEmpty && !isProcessing {
                Text("No text yet — use Crop to recognise a region.")
                    .font(.body).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                TextEditor(text: $recognizedText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
            }

            if let error = errorText { errorLabel(error).padding(.horizontal) }

            HStack {
                Button("Cancel") { captureVM.reset(); dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Use Text") {
                    captureVM.saveTextCapture(recognizedText, captureMethod: .imageFile)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
            }
            .padding([.horizontal, .bottom])
        }
    }

    private func errorLabel(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
    }

    // MARK: - Actions

    private func loadImageFiles(_ urls: [URL]) async {
        isLoadingImages = true
        loadedImages = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url),
               let ns = NSImage(data: data),
               let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                loadedImages.append(cg)
            }
        }
        isLoadingImages = false

        if loadedImages.isEmpty {
            errorText = "Could not load any images from the selected file(s)."
        } else {
            cropImageIndex = 0
            showingCropView = true
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
