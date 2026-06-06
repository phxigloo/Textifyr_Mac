import Foundation
import AppKit
import UniformTypeIdentifiers
import TextifyrServices

// MARK: - Extraction result

struct ShareExtractionResult {
    let captureMethodRaw: String
    let rawText: String
    let audioFileName: String?     // non-nil only for audio/video shares
    let sourceTitle: String
    let previewText: String        // first ~200 chars for display
    let previewImage: NSImage?
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

            // URL (web page)
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                let url = try await loadURL(provider)
                let extracted = (try? await WebExtractionService.extractText(from: url)) ?? url.absoluteString
                return result(method: "webURL", text: extracted, title: url.host ?? url.absoluteString)
            }

            // PDF (extractText is synchronous)
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                let fileURL = try await copyToTemp(provider, type: UTType.pdf)
                let text = (try? PDFTextService.extractText(from: fileURL)) ?? ""
                return result(method: "pdf", text: text, title: fileURL.lastPathComponent)
            }

            // Image (static image — run OCR)
            let imageTypes: [UTType] = [.image, .png, .jpeg, .tiff, .heic, .bmp, .gif]
            for imgType in imageTypes where provider.hasItemConformingToTypeIdentifier(imgType.identifier) {
                let fileURL = try await copyToTemp(provider, type: imgType)
                let nsImage = NSImage(contentsOf: fileURL)
                var text = ""
                if let cg = nsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    text = (try? await VisionTextService.recognizeText(in: cg)) ?? ""
                }
                return ShareExtractionResult(
                    captureMethodRaw: "imageFile", rawText: text,
                    audioFileName: nil, sourceTitle: fileURL.lastPathComponent,
                    previewText: text.isEmpty ? "(no text detected)" : String(text.prefix(200)),
                    previewImage: nsImage
                )
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

    private static func result(method: String, text: String, title: String) -> ShareExtractionResult {
        ShareExtractionResult(
            captureMethodRaw: method, rawText: text, audioFileName: nil,
            sourceTitle: title,
            previewText: String(text.prefix(200)),
            previewImage: nil
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
