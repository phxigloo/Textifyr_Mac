import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

struct PDFInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedURL: URL?
    @State private var selectedFileName: String?
    @State private var totalPages: Int?
    @State private var startPage = 1
    @State private var endPage = 1
    @State private var extractedText = ""
    @State private var isExtracting = false
    @State private var showFilePicker = false
    @State private var showingCropView = false
    @State private var cropPageImage: CGImage?
    @State private var cropPageNumber = 1
    @State private var errorText: String?
    @State private var warningText: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Import PDF")
                .font(.title2).bold()
                .padding(.top, 24)

            fileSelectionArea
                .padding(.horizontal)

            if let total = totalPages, total > 1 {
                pageRangeSelector(total: total)
                    .padding(.horizontal)
            }

            if isExtracting {
                ProgressView("Extracting text…").padding(.horizontal)
            }

            Divider()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $extractedText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)

                if extractedText.isEmpty && !isExtracting {
                    Text("Select a PDF, then use Extract Text to pull out selectable text, or set From and To to the same page number and use Crop Page to draw a region and recognise text from a photo or scan.")
                        .foregroundStyle(.secondary).font(.body)
                        .padding(.horizontal, 8).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)

            if let warning = warningText {
                Text(warning).font(.caption).foregroundStyle(.orange).padding(.horizontal)
            }
            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            controlsBar
                .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 560, minHeight: 500)
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            handleFileSelection(result)
        }
        .sheet(isPresented: $showingCropView) {
            if let image = cropPageImage {
                NavigationStack {
                    CroppableImageView(
                        image: image,
                        onCrop: { cropped in
                            showingCropView = false
                            Task { await processCroppedImage(cropped) }
                        },
                        onCancel: { showingCropView = false }
                    )
                    .navigationTitle("Crop PDF Page \(cropPageNumber)")
                }
                .frame(minWidth: 560, minHeight: 480)
            }
        }
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { dismiss() }
        }
    }

    // MARK: - File selection

    @ViewBuilder private var fileSelectionArea: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext").font(.title2).foregroundStyle(.secondary)

            if let name = selectedFileName {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline).lineLimit(1)
                    if let total = totalPages {
                        Text("\(total) page\(total == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No PDF selected").foregroundStyle(.secondary)
            }

            Spacer()

            Button("Choose PDF…") { showFilePicker = true }
                .buttonStyle(.bordered)
                .disabled(isExtracting)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Page range

    private var isPageRangeValid: Bool {
        guard let total = totalPages else { return true }
        return startPage >= 1 && startPage <= total
            && endPage >= startPage && endPage <= total
    }

    private var isSinglePageSelected: Bool { startPage == endPage && isPageRangeValid }

    @ViewBuilder
    private func pageRangeSelector(total: Int) -> some View {
        HStack(spacing: 12) {
            Text("Pages:").font(.subheadline).foregroundStyle(.secondary)
            Text("From").font(.subheadline)
            pageField(value: $startPage, total: total)
            Text("To").font(.subheadline)
            pageField(value: $endPage, total: total)
            Text("of \(total)").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private func pageField(value: Binding<Int>, total: Int) -> some View {
        let invalid = value.wrappedValue < 1 || value.wrappedValue > total
        TextField("", value: value, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(invalid ? Color.red : Color.clear, lineWidth: 1.5))
    }

    // MARK: - Controls

    @ViewBuilder private var controlsBar: some View {
        HStack(spacing: 16) {
            if selectedURL != nil && !isExtracting {
                Button("Crop Page") { cropAndShowPage() }
                    .buttonStyle(.bordered)
                    .disabled(!isSinglePageSelected)
                    .help(isSinglePageSelected ? "Crop a region of this page for OCR" : "Set From and To to the same page to crop")

                Button("Clear") { extractedText = "" }
                    .buttonStyle(.bordered)
                    .disabled(extractedText.isEmpty)
            }

            Spacer()

            Button("Cancel") { captureVM.reset(); dismiss() }
                .buttonStyle(.bordered)

            if isExtracting {
                Button("Stop") { isExtracting = false }
                    .buttonStyle(.bordered)
            } else {
                Button("Extract Text") { Task { await extractText() } }
                    .buttonStyle(.bordered)
                    .disabled(selectedURL == nil || !isPageRangeValid)
            }

            Button("Use Text") {
                captureVM.saveTextCapture(extractedText, captureMethod: .pdf)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isExtracting || extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Actions

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            selectedURL = url
            selectedFileName = url.lastPathComponent
            errorText = nil

            if let pages = PDFTextService.pageCount(for: url) {
                totalPages = pages
                startPage = 1
                endPage = min(pages, AppConstants.maxPDFPages)
                if pages > AppConstants.maxPDFPages {
                    warningText = "This PDF has \(pages) pages. Only the first \(AppConstants.maxPDFPages) pages can be extracted."
                } else {
                    warningText = nil
                }
            }

        case .failure(let error):
            errorText = error.localizedDescription
        }
    }

    private func extractText() async {
        guard let url = selectedURL, isPageRangeValid else { return }
        isExtracting = true
        errorText = nil
        let range = (startPage - 1)...(endPage - 1)
        do {
            let text = try PDFTextService.extractText(from: url, pageRange: range)
            extractedText = text
            if text.count >= AppConstants.maxImportCharacters {
                warningText = "Text was truncated to \(AppConstants.maxImportCharacters) characters."
            }
        } catch {
            errorText = error.localizedDescription
        }
        isExtracting = false
    }

    private func cropAndShowPage() {
        guard let url = selectedURL else { return }
        cropPageNumber = startPage
        if let image = PDFTextService.renderPage(from: url, pageIndex: startPage - 1) {
            cropPageImage = image
            showingCropView = true
        } else {
            errorText = "Could not render PDF page for cropping."
        }
    }

    private func processCroppedImage(_ cgImage: CGImage) async {
        guard !isExtracting else { return }
        isExtracting = true
        do {
            let text = try await VisionTextService.recognizeText(in: cgImage)
            if text.isEmpty {
                errorText = "No text detected in the cropped region."
            } else {
                let separator = "\n\n--- Crop (Page \(cropPageNumber)) ---\n\n"
                extractedText = extractedText.isEmpty ? text : extractedText + separator + text
            }
        } catch {
            errorText = error.localizedDescription
        }
        isExtracting = false
    }
}
