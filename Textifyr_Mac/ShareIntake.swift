import Foundation
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

/// Turns a `PendingShareItem` (from the Share Extension queue, a window drop, or a
/// Dock-icon drop) into content inside a document. Shared by `ContentView` and the
/// drag-and-drop drop targets so every entry point behaves identically.
@MainActor
enum ShareIntake {

    /// Consumes one item: text/PDF/web content is inserted directly as a source;
    /// images, audio, and video are handed to their interactive wizard.
    static func consume(_ item: PendingShareItem, context: ModelContext, appState: AppState) {
        let document: TextifyrDocument
        if let targetID = item.targetDocumentID {
            let allDocs = (try? context.fetch(FetchDescriptor<TextifyrDocument>())) ?? []
            document = allDocs.first(where: { $0.id == targetID }) ?? makeNewDocument(title: item.sourceTitle, context: context)
        } else {
            document = makeNewDocument(title: item.sourceTitle, context: context)
        }

        // Embed Image: load from the App Group SharedImages and open the wizard.
        if item.captureMethodRaw == "imageFile", let fileName = item.sharedImageFileName {
            appState.selectedDocument = document
            try? context.save()
            if let dir = ShareExtensionQueue.sharedImagesDirectory {
                appState.pendingSharedImageData = try? Data(contentsOf: dir.appendingPathComponent(fileName))
            }
            appState.pendingSourceMethod = .smartVision
            return
        }

        // Audio / video: hand the file to the transcription wizard.
        if item.captureMethodRaw == "audioFile" || item.captureMethodRaw == "videoAudio",
           let audioURL = item.resolvedAudioURL() {
            appState.selectedDocument = document
            try? context.save()
            appState.pendingSharedAudioURL = audioURL
            appState.pendingSourceMethod = CaptureMethod(rawValue: item.captureMethodRaw) ?? .audioFile
            return
        }

        // Text-based content: insert a source directly (extraction already done).
        let method = CaptureMethod(rawValue: item.captureMethodRaw) ?? .rtfEditor
        let order = (document.sourceSessions ?? []).count
        let session = SourceSession(captureMethod: method, rawText: item.rawText, sortOrder: order)
        context.insert(session)
        document.sourceSessions = (document.sourceSessions ?? []) + [session]
        document.modificationDate = Date()
        try? context.save()
        appState.selectedDocument = document
    }

    static func makeNewDocument(title: String, context: ModelContext) -> TextifyrDocument {
        let trimmed = title.prefix(80).trimmingCharacters(in: .whitespacesAndNewlines)
        let doc = TextifyrDocument(title: trimmed.isEmpty ? "Shared Content" : trimmed)
        context.insert(doc)
        return doc
    }
}

/// Handles files dropped onto the app (window areas or the Dock icon) by running
/// them through the shared `FileImportService` and consuming the results.
@MainActor
enum FileDropImporter {

    /// Imports dropped files. When `targetDocumentID` is nil a single new document
    /// is created and every dropped file is added to it; otherwise the files are
    /// added to the existing document.
    static func handleDrop(urls: [URL], into targetDocumentID: UUID?, context: ModelContext, appState: AppState) {
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { return }
        Task {
            var target = targetDocumentID
            for url in fileURLs {
                do {
                    let item = try await FileImportService.makePendingItem(from: url, targetDocumentID: target)
                    ShareIntake.consume(item, context: context, appState: appState)
                    // Subsequent files in the same drop join the document the first
                    // one created (so dropping 3 files makes one document, not three).
                    if target == nil { target = appState.selectedDocument?.id }
                } catch {
                    appState.showError(error.localizedDescription)
                }
            }
        }
    }
}
