import Foundation
import AppKit
import UniformTypeIdentifiers
import Vision
import CoreImage
import TextifyrServices

// MARK: - Extraction result

struct ShareExtractionResult {
    let captureMethodRaw: String
    let rawText: String
    let audioFileName: String?     // non-nil only for audio/video shares
    let sourceTitle: String
    let previewText: String        // first ~200 chars for display
    let previewImage: NSImage?
    /// Raw image bytes kept for deferred OCR/embed at commit time; nil for non-image shares.
    let imageData: Data?

    var isImageShare: Bool { imageData != nil }
}

// MARK: - Handlers

enum ShareContentHandlers {

    static func extract(from extensionItem: NSExtensionItem) async throws -> ShareExtractionResult {
        guard let providers = extensionItem.attachments, !providers.isEmpty else {
            throw ShareExtractionError.noContent
        }

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

            // PDF (extractText is synchronous)
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                let fileURL = try await copyToTemp(provider, type: UTType.pdf)
                let text = (try? PDFTextService.extractText(from: fileURL)) ?? ""
                return result(method: "pdf", text: text, title: fileURL.lastPathComponent)
            }

            // Image (static image — run OCR)
            // Photos shares NSImage objects; Finder/web share raw data. Try both paths.
            let isImageProvider = provider.canLoadObject(ofClass: NSImage.self) ||
                [UTType.image, .png, .jpeg, .tiff, .heic, .bmp, .gif].contains(where: {
                    provider.hasItemConformingToTypeIdentifier($0.identifier)
                })

            if isImageProvider {
                // Load image bytes — specific type first (Finder/Preview),
                // fall back to NSImage object (Photos) serialised to TIFF.
                var imageData: Data? = nil
                var nsImage: NSImage? = nil

                let specificTypes: [UTType] = [.png, .jpeg, .tiff, .heic, .bmp, .gif]
                if let loadType = specificTypes.first(where: {
                    provider.hasItemConformingToTypeIdentifier($0.identifier)
                }) {
                    imageData = await withCheckedContinuation { cont in
                        provider.loadDataRepresentation(forTypeIdentifier: loadType.identifier) { data, _ in
                            cont.resume(returning: data)
                        }
                    }
                }

                if let data = imageData {
                    nsImage = NSImage(data: data)
                } else if provider.canLoadObject(ofClass: NSImage.self) {
                    nsImage = await withCheckedContinuation { cont in
                        _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                            cont.resume(returning: object as? NSImage)
                        }
                    }
                    imageData = nsImage?.tiffRepresentation
                }

                let title = provider.suggestedName ?? "Image"
                // captureMethodRaw "imagePending" is a sentinel: OCR or embed chosen at commit time.
                return ShareExtractionResult(
                    captureMethodRaw: "imagePending", rawText: "",
                    audioFileName: nil, sourceTitle: title,
                    previewText: "Choose how to add this image below.",
                    previewImage: nsImage,
                    imageData: imageData
                )
            }

            // CSV / TSV / plain-text files shared from Finder
            let textFileTypes: [UTType] = [.commaSeparatedText, .tabSeparatedText, .utf8PlainText, .plainText]
            for txtType in textFileTypes where provider.hasItemConformingToTypeIdentifier(txtType.identifier) {
                let text = try await loadString(provider, type: txtType)
                return result(method: "rtfEditor", text: text, title: provider.suggestedName ?? "Text File")
            }

            // Audio / video — copy to App Group; main app transcribes
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
                    previewText: "Audio file — tap to transcribe in Textifyr",
                    previewImage: nil
                )
            }
        }

        throw ShareExtractionError.unsupportedType
    }

    // MARK: - Private helpers

    // MARK: - OCR (Vision direct — bypasses VisionTextService which may be unavailable in extension sandbox)

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

    // MARK: - Image save (for Embed Image path)

    static func saveToSharedImages(_ data: Data?) -> String? {
        guard let data, let dir = ShareExtensionQueue.sharedImagesDirectory else { return nil }
        let name = UUID().uuidString + ".jpg"
        let dest = dir.appendingPathComponent(name)
        // Prefer JPEG encoding for space; fall back to raw data if conversion fails
        let writeData: Data
        if let rep = NSBitmapImageRep(data: data),
           let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            writeData = jpg
        } else {
            writeData = data
        }
        return (try? writeData.write(to: dest, options: .atomic)) != nil ? name : nil
    }

    // MARK: - Private helpers

    private static func result(method: String, text: String, title: String) -> ShareExtractionResult {
        ShareExtractionResult(
            captureMethodRaw: method, rawText: text, audioFileName: nil,
            sourceTitle: title,
            previewText: String(text.prefix(200)),
            previewImage: nil,
            imageData: nil
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
    case noContent, unsupportedType, couldNotLoad
    var errorDescription: String? {
        switch self {
        case .noContent:       return "No content was shared."
        case .unsupportedType: return "Textifyr doesn't support this content type."
        case .couldNotLoad:    return "The shared content could not be loaded."
        }
    }
}
