import SwiftUI
import SwiftData
import PhotosUI
import AppKit
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

struct PhotoLibraryInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var currentImage: CGImage? = nil
    @State private var recognizedText = ""
    @State private var isLoadingImage = false
    @State private var isProcessing = false
    @State private var showingCropView = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Photo Library")
                .font(.title2).bold()
                .padding(.top, 24)

            if currentImage == nil && !isLoadingImage {
                selectionContent
            } else if isLoadingImage {
                loadingContent
            } else {
                reviewContent
            }
        }
        .frame(width: 560)
        .sheet(isPresented: $showingCropView) {
            if let image = currentImage {
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
                .frame(minWidth: 560, minHeight: 480)
            }
        }
        .alert("Photo Error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { errorText = nil }
        } message: { Text(errorText ?? "") }
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { dismiss() }
        }
        .onChange(of: selectedItem) { _, item in
            guard let item else { return }
            Task { await loadPickedPhoto(item) }
        }
    }

    // MARK: - Selection

    @ViewBuilder private var selectionContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("Pick a photo from your library to extract text using OCR. Use \"Pick More\" after each photo to add additional ones.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error = errorText { errorLabel(error) }

            PhotosPicker(
                selection: $selectedItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Choose Photo…", systemImage: "photo.on.rectangle")
            }
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
            Text("Loading photo…").font(.headline)
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

                Button("Crop") { showingCropView = true }
                    .buttonStyle(.bordered)

                Button("Clear") { recognizedText = "" }
                    .buttonStyle(.bordered)
                    .disabled(recognizedText.isEmpty)

                PhotosPicker(
                    selection: $selectedItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Text("Pick More")
                }
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
                    captureVM.saveTextCapture(recognizedText, captureMethod: .photoLibrary)
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

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        isLoadingImage = true
        currentImage = nil
        defer { isLoadingImage = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let ns = NSImage(data: data),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorText = "Could not load the selected photo."
            return
        }
        currentImage = cg
        showingCropView = true
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
    return PhotoLibraryInputView(captureVM: captureVM)
        .modelContainer(c)
        .frame(width: 560, height: 440)
}
