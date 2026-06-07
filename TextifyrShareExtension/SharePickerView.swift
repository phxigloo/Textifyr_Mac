import SwiftUI
import AppKit
import TextifyrServices

// MARK: - Main picker view

struct SharePickerView: View {
    let extensionItem: NSExtensionItem
    let onComplete: (PendingShareItem?) -> Void   // nil = cancelled

    @State private var phase: Phase = .extracting
    @State private var extraction: ShareExtractionResult?
    @State private var selectedDocumentID: UUID? = nil    // nil = New Document
    @State private var recentDocs: [RecentDocumentInfo] = []
    @State private var errorMessage: String?
    @State private var imageMode: ImageMode = .ocr

    enum Phase { case extracting, picking, confirming, done }
    enum ImageMode { case ocr, embed }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch phase {
            case .extracting:
                extractingContent
            case .picking:
                pickingContent
            case .confirming:
                confirmingContent
            case .done:
                doneContent
            }
        }
        .frame(width: 400)
        .task { await runExtraction() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image("AppIcon")
                .resizable()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Add to Textifyr")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Phase: extracting

    private var extractingContent: some View {
        VStack(spacing: 14) {
            if errorMessage == nil {
                ProgressView("Extracting content…")
                    .controlSize(.regular)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.red)
                Text(errorMessage!)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Close") { onComplete(nil) }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Phase: picking
    // ScrollView fills all available height; buttons are pinned outside it so
    // they remain visible regardless of how tall the host app makes the panel.

    private var pickingContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let e = extraction {
                        previewCard(e)
                            .padding(16)
                    }

                    // Image mode picker — only shown for image shares
                    if extraction?.isImageShare == true {
                        Picker("", selection: $imageMode) {
                            Text("Extract Text (OCR)").tag(ImageMode.ocr)
                            Text("Embed Image").tag(ImageMode.embed)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)

                        Text(imageMode == .ocr
                             ? "OCR runs on the image and the text is added to your document."
                             : "The image opens in the Embed Image wizard in Textifyr.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                    }

                    Divider()

                    Text("Add to")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    docRow(id: nil, title: "New Document", icon: "doc.badge.plus")

                    if !recentDocs.isEmpty {
                        Text("Recent")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                            .padding(.bottom, 2)

                        ForEach(recentDocs) { doc in
                            docRow(id: doc.id, title: doc.title, icon: "doc.text")
                        }
                    }
                }
            }

            Divider()

            // Fixed bottom toolbar — always visible
            HStack {
                Button("Cancel") { onComplete(nil) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Add to Textifyr") { commitAdd() }
                    .buttonStyle(.borderedProminent)
                    .disabled(extraction == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func docRow(id: UUID?, title: String, icon: String) -> some View {
        let isSelected = selectedDocumentID == id
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Text(title)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.white)
                    .font(.caption.bold())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedDocumentID = id }
    }

    @ViewBuilder
    private func previewCard(_ e: ShareExtractionResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let img = e.previewImage {
                Image(nsImage: img)
                    .resizable().scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: iconName(for: e.captureMethodRaw))
                    .font(.system(size: 24))
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(e.sourceTitle)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(e.previewText.isEmpty ? "No text content" : e.previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Phase: confirming

    private var confirmingContent: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Adding…")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Phase: done

    private var doneContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)

            Text("Added to Textifyr")
                .font(.headline)

            Text("Open Textifyr to view and process the content.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Close") { onComplete(nil) }
                    .buttonStyle(.bordered)
                Button("Open Textifyr") {
                    if let url = URL(string: "textifyr://open-share") {
                        NSWorkspace.shared.open(url)
                    }
                    onComplete(nil)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Actions

    private func runExtraction() async {
        recentDocs = ShareExtensionQueue.recentDocuments()
        do {
            extraction = try await ShareContentHandlers.extract(from: extensionItem)
            phase = .picking
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commitAdd() {
        guard let e = extraction else { return }
        phase = .confirming
        Task {
            var captureMethodRaw = e.captureMethodRaw
            var rawText = e.rawText
            var sharedImageFileName: String? = nil

            if e.isImageShare {
                if imageMode == .ocr {
                    rawText = await ShareContentHandlers.runOCR(imageData: e.imageData)
                    // Never enqueue an empty session. If OCR found no text (or the
                    // image data couldn't be loaded), tell the user instead of
                    // silently creating a blank document.
                    if rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await MainActor.run {
                            errorMessage = e.imageData == nil
                                ? "This image couldn't be read. Try sharing it from Finder or Preview instead, or choose Embed Image to add the picture without OCR."
                                : "No text was found in this image. If it contains text, try a clearer or higher-resolution version, or choose Embed Image to add the picture instead."
                            phase = .extracting
                        }
                        return
                    }
                    captureMethodRaw = "rtfEditor"
                } else {
                    sharedImageFileName = ShareContentHandlers.saveToSharedImages(e.imageData)
                    captureMethodRaw = "imageFile"
                }
            }

            let item = PendingShareItem(
                captureMethodRaw: captureMethodRaw,
                rawText: rawText,
                audioFileName: e.audioFileName,
                sharedImageFileName: sharedImageFileName,
                sourceTitle: e.sourceTitle,
                targetDocumentID: selectedDocumentID
            )
            try? ShareExtensionQueue.enqueue(item)
            phase = .done
        }
    }

    // MARK: - Helpers

    private func iconName(for captureMethodRaw: String) -> String {
        switch captureMethodRaw {
        case "webURL":    return "globe"
        case "pdf":       return "doc.richtext"
        case "imageFile": return "photo"
        case "audioFile": return "waveform"
        case "rtfEditor": return "doc.text"
        default:          return "paperclip"
        }
    }
}
