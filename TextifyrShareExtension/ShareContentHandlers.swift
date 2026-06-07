import Foundation
import AppKit
import PDFKit
import UniformTypeIdentifiers
import Vision
import CoreImage
import TextifyrServices

// MARK: - Extraction result

struct ShareExtractionResult {
    let captureMethodRaw: String
    let rawText: String
    let audioFileName: String?      // non-nil only for audio/video shares
    let sourceTitle: String
    let previewText: String         // first ~200 chars for display
    let previewImage: NSImage?
    /// Raw image bytes kept for deferred OCR/embed at commit time; nil for non-image shares.
    let imageData: Data?
    /// True whenever the share is an image, even if imageData could not be loaded.
    /// Separating this from imageData lets the picker show the OCR/Embed control
    /// even when image data loading failed (e.g. Photos sandbox restrictions).
    let isImageShare: Bool
}

// MARK: - Handlers

enum ShareContentHandlers {

    static func extract(from extensionItem: NSExtensionItem) async throws -> ShareExtractionResult {
        guard let providers = extensionItem.attachments, !providers.isEmpty else {
            throw ShareExtractionError.noContent
        }

        var firstUnsupportedHint: String? = nil

        for provider in providers {
            // Plain text
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                let text = try await loadString(provider, type: UTType.plainText)
                return result(method: "rtfEditor", text: text, title: "Shared Text")
            }

            // URL (web page only — file:// URLs fall through to file-type handlers below)
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                let url = try await loadURL(provider)
                if !url.isFileURL {
                    let extracted = (try? await WebExtractionService.extractText(from: url)) ?? url.absoluteString
                    return result(method: "webURL", text: extracted, title: url.host ?? url.absoluteString)
                }
            }

            // PDF
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                let fileURL = try await copyToTemp(provider, type: UTType.pdf)
                // Try native text extraction first
                if let text = try? PDFTextService.extractText(from: fileURL), !text.isEmpty {
                    return result(method: "pdf", text: text, title: fileURL.lastPathComponent)
                }
                // Scanned/image PDF: OCR every page via PDFKit render + Vision
                let ocrText = await ocrPDFPages(at: fileURL)
                if !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return result(method: "pdf", text: ocrText, title: fileURL.lastPathComponent)
                }
                throw ShareExtractionError.cannotExtractPDF
            }

            // Rich Text (.rtf) — extract the plain text; the document pipeline re-renders to RTF
            if provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier) {
                let fileURL = try await copyToTemp(provider, type: UTType.rtf)
                let data = try Data(contentsOf: fileURL)
                if let attr = try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil), !attr.string.isEmpty {
                    return result(method: "rtfEditor", text: attr.string, title: fileURL.lastPathComponent)
                }
            }

            // Image (static image — Finder/Preview share raw data; Photos shares NSImage objects)
            let imageTypes: [UTType] = [.png, .jpeg, .tiff, .heic, .bmp, .gif, .webP]
            let isImageProvider = provider.canLoadObject(ofClass: NSImage.self) ||
                ([UTType.image] + imageTypes).contains(where: {
                    provider.hasItemConformingToTypeIdentifier($0.identifier)
                })

            if isImageProvider {
                var imageData: Data? = nil
                var nsImage: NSImage? = nil

                // 1. Try loadDataRepresentation for a known specific type
                if let loadType = imageTypes.first(where: {
                    provider.hasItemConformingToTypeIdentifier($0.identifier)
                }) {
                    imageData = await withCheckedContinuation { cont in
                        provider.loadDataRepresentation(forTypeIdentifier: loadType.identifier) { data, _ in
                            cont.resume(returning: data)
                        }
                    }
                }

                // 2. Generic public.image fallback
                if imageData == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    imageData = await withCheckedContinuation { cont in
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                            cont.resume(returning: data)
                        }
                    }
                }

                // 3. loadFileRepresentation — works for Photos and apps that only expose a file URL
                if imageData == nil {
                    let tryTypes = (imageTypes.map(\.identifier) + [UTType.image.identifier]).filter {
                        provider.hasItemConformingToTypeIdentifier($0)
                    }
                    for typeID in tryTypes {
                        let data: Data? = await withCheckedContinuation { cont in
                            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                                guard let url else { cont.resume(returning: nil); return }
                                cont.resume(returning: try? Data(contentsOf: url))
                            }
                        }
                        if let data { imageData = data; break }
                    }
                }

                // 4. NSImage object (Photos — CIImage-backed) → JPEG/TIFF.
                // `cgImage(forProposedRect:)` frequently returns nil for the
                // CIImage-backed NSImage that Photos vends, which previously left
                // imageData nil and made OCR run on nothing. tiffRepresentation
                // forces a rasterisation and is far more reliable, so try it first.
                if imageData == nil, provider.canLoadObject(ofClass: NSImage.self) {
                    nsImage = await withCheckedContinuation { cont in
                        _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                            cont.resume(returning: object as? NSImage)
                        }
                    }
                    if let img = nsImage {
                        imageData = jpegData(from: img)
                    }
                }

                if let data = imageData, nsImage == nil {
                    nsImage = NSImage(data: data)
                }

                // Final guarantee: if we have any NSImage but still no bytes,
                // rasterise it so OCR/embed always has data to work with.
                if imageData == nil, let img = nsImage {
                    imageData = jpegData(from: img)
                }

                let title = provider.suggestedName ?? "Image"
                // isImageShare is always true here, regardless of whether imageData loaded.
                // captureMethodRaw "imagePending" is a sentinel: OCR or embed chosen at commit time.
                return ShareExtractionResult(
                    captureMethodRaw: "imagePending", rawText: "",
                    audioFileName: nil, sourceTitle: title,
                    previewText: "Choose how to add this image below.",
                    previewImage: nsImage,
                    imageData: imageData,
                    isImageShare: true
                )
            }

            // CSV / TSV / plain-text files shared from Finder
            let textFileTypes: [UTType] = [.commaSeparatedText, .tabSeparatedText, .utf8PlainText, .plainText]
            for txtType in textFileTypes where provider.hasItemConformingToTypeIdentifier(txtType.identifier) {
                let text = try await loadString(provider, type: txtType)
                return result(method: "rtfEditor", text: text, title: provider.suggestedName ?? "Text File")
            }

            // Audio / video — copy to App Group; main app transcribes via wizard
            let audioTypes: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie, .mpeg4Movie, .quickTimeMovie]
            for audioType in audioTypes where provider.hasItemConformingToTypeIdentifier(audioType.identifier) {
                let fileURL = try await copyToTemp(provider, type: audioType)
                let destFileName = fileURL.lastPathComponent
                if let audioDir = ShareExtensionQueue.sharedAudioDirectory {
                    let dest = audioDir.appendingPathComponent(destFileName)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: fileURL, to: dest)
                }
                return ShareExtractionResult(
                    captureMethodRaw: "audioFile", rawText: "",
                    audioFileName: destFileName,
                    sourceTitle: fileURL.lastPathComponent,
                    previewText: "Audio/video — will open in transcription wizard",
                    previewImage: nil,
                    imageData: nil,
                    isImageShare: false
                )
            }

            // Record the first unsupported provider for a hint
            if firstUnsupportedHint == nil {
                firstUnsupportedHint = conversionHint(for: provider)
            }
        }

        throw ShareExtractionError.unsupported(hint: firstUnsupportedHint)
    }

    // MARK: - OCR

    /// Runs Vision OCR directly on image data (bypasses VisionTextService which may be unavailable in the extension sandbox).
    static func runOCR(imageData: Data?) async -> String {
        guard let data = imageData else { return "" }
        let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
        guard let ci = CIImage(data: data, options: [.applyOrientationProperty: true]),
              let cg = ciCtx.createCGImage(ci, from: ci.extent) else { return "" }
        return await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { request, _ in
                let obs = request.results as? [VNRecognizedTextObservation] ?? []
                let text = obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                cont.resume(returning: text)
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        }
    }

    /// Rasterises an NSImage to JPEG data, falling back to TIFF. Reliable for the
    /// CIImage-backed images that Photos vends, where cgImage(forProposedRect:) fails.
    private static func jpegData(from img: NSImage) -> Data? {
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) ?? tiff
        }
        if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let ci = CIImage(cgImage: cg)
            let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
            return ciCtx.jpegRepresentation(of: ci, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return nil
    }

    // MARK: - Image save (for Embed Image path)

    static func saveToSharedImages(_ data: Data?) -> String? {
        guard let data, let dir = ShareExtensionQueue.sharedImagesDirectory else { return nil }
        let name = UUID().uuidString + ".jpg"
        let dest = dir.appendingPathComponent(name)
        let writeData: Data
        if let rep = NSBitmapImageRep(data: data),
           let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            writeData = jpg
        } else {
            writeData = data
        }
        return (try? writeData.write(to: dest, options: .atomic)) != nil ? name : nil
    }

    // MARK: - PDF OCR (scanned pages)

    private static func ocrPDFPages(at url: URL) async -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        let pageCount = min(document.pageCount, AppConstants.maxPDFPages)
        var pages: [String] = []
        for i in 0..<pageCount {
            guard let cg = PDFTextService.renderPage(from: url, pageIndex: i) else { continue }
            let text: String = await withCheckedContinuation { cont in
                let req = VNRecognizeTextRequest { request, _ in
                    let obs = request.results as? [VNRecognizedTextObservation] ?? []
                    cont.resume(returning: obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
                }
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
            }
            if !text.isEmpty { pages.append(text) }
        }
        return pages.joined(separator: "\n\n")
    }

    // MARK: - Unsupported type hint

    private static func conversionHint(for provider: NSItemProvider) -> String? {
        let ids = Set(provider.registeredTypeIdentifiers)
        let name = provider.suggestedName ?? ""
        let ext = (name as NSString).pathExtension.lowercased()

        if ids.contains("com.apple.iwork.numbers.numbers") || ext == "numbers" {
            return "In Numbers, choose File → Export To → CSV (or TSV), then share from Finder."
        }
        if ids.contains("com.apple.iwork.pages.pages") || ext == "pages" {
            return "In Pages, choose File → Export To → Plain Text, Rich Text (RTF), or PDF, then share from Finder."
        }
        if ids.contains("com.apple.iwork.keynote.key") || ext == "key" {
            return "In Keynote, choose File → Export To → PDF, then share from Finder."
        }
        if ["xlsx", "xls"].contains(ext) {
            return "In Excel (or Numbers), export as CSV or TSV, then share from Finder."
        }
        if ["docx", "doc"].contains(ext) {
            return "In Word (or Pages), export as Plain Text, Rich Text (RTF), or PDF, then share from Finder."
        }
        if ["pptx", "ppt"].contains(ext) {
            return "In PowerPoint (or Keynote), export as PDF, then share from Finder."
        }
        if ext == "sketch" {
            return "In Sketch, export individual artboards as PNG or PDF, then share from Finder."
        }
        if !name.isEmpty {
            return "Convert \"\(name)\" to plain text, RTF, PDF, an image, or audio and share from Finder."
        }
        return nil
    }

    // MARK: - Private helpers

    private static func result(method: String, text: String, title: String) -> ShareExtractionResult {
        ShareExtractionResult(
            captureMethodRaw: method, rawText: text, audioFileName: nil,
            sourceTitle: title,
            previewText: String(text.prefix(200)),
            previewImage: nil,
            imageData: nil,
            isImageShare: false
        )
    }

    private static func loadString(_ provider: NSItemProvider, type: UTType) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            provider.loadItem(forTypeIdentifier: type.identifier) { item, error in
                if let error { cont.resume(throwing: error); return }
                if let s = item as? String { cont.resume(returning: s); return }
                if let data = item as? Data, let s = String(data: data, encoding: .utf8) { cont.resume(returning: s); return }
                cont.resume(throwing: ShareExtractionError.couldNotLoad)
            }
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, error in
                if let error { cont.resume(throwing: error); return }
                if let url = item as? URL { cont.resume(returning: url); return }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { cont.resume(returning: url); return }
                cont.resume(throwing: ShareExtractionError.couldNotLoad)
            }
        }
    }

    private static func copyToTemp(_ provider: NSItemProvider, type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                if let error { cont.resume(throwing: error); return }
                guard let url else { cont.resume(throwing: ShareExtractionError.couldNotLoad); return }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    cont.resume(returning: dest)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Error

enum ShareExtractionError: LocalizedError {
    case noContent
    case unsupported(hint: String?)
    case couldNotLoad
    case cannotExtractPDF

    var errorDescription: String? {
        switch self {
        case .noContent:
            return "No content was shared."
        case .unsupported(let hint):
            var msg = "Textifyr can't use this file directly."
            if let hint { msg += "\n\n\(hint)" }
            return msg
        case .couldNotLoad:
            return "The shared content could not be loaded."
        case .cannotExtractPDF:
            return "This PDF contains only scanned images and no text could be extracted from it. Try sharing a PDF with selectable text, or scan at a higher resolution."
        }
    }
}
