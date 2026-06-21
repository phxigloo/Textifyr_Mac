import Foundation
import AppKit
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

/// Serialises all file intake — Share-Extension queue, Dock-icon drops, and
/// window drops — so files are extracted and added strictly one at a time. When
/// an item opens an interactive wizard (audio/video transcription, image embed),
/// the queue pauses until that wizard finishes before starting the next file.
@MainActor
final class DropImportCoordinator {
    static let shared = DropImportCoordinator()
    private init() {}

    /// Items whose consumption opens a wizard the user must complete/cancel.
    private enum Work {
        case url(URL, target: UUID?, groupKey: Int?, imageMode: ImageImportMode)
        case item(PendingShareItem, groupKey: Int?)
    }

    /// A batch of images awaiting an OCR/Embed choice. `onResolve` runs with the
    /// chosen mode (not called on cancel) so different destinations — adding as
    /// sources vs. inserting into the Output — can share one prompt.
    private struct PendingImageBatch {
        let imageCount: Int
        let appState: AppState
        let onResolve: (ImageImportMode) -> Void
    }

    private var queue: [Work] = []
    private var groupDocuments: [Int: UUID] = [:]   // batch → the document it created
    private var nextGroupKey = 0
    private var processing = false
    private var awaitingWizard = false
    private var context: ModelContext?
    private weak var appState: AppState?

    private var pendingImageBatches: [PendingImageBatch] = []

    /// A fresh key so a multi-file drop collapses into one new document.
    func newGroupKey() -> Int { defer { nextGroupKey += 1 }; return nextGroupKey }

    /// Enqueue file URLs (window/Dock drops) for extraction + consumption.
    func enqueueURLs(_ urls: [URL], target: UUID?, groupKey: Int?, imageMode: ImageImportMode = .ocr,
                     context: ModelContext, appState: AppState) {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        self.context = context
        self.appState = appState
        queue.append(contentsOf: files.map { .url($0, target: target, groupKey: groupKey, imageMode: imageMode) })
        pump()
    }

    // MARK: - Per-drop image OCR/Embed prompt

    static let largeBatchThreshold = 15
    private static let suppressLargeBatchKey = "suppressLargeBatchWarning"

    /// Handles a drop: warns for large batches, then (if images are present) asks how
    /// to add them, then enqueues with that choice.
    func handleDroppedFiles(_ urls: [URL], target: UUID?, groupKey: Int?, context: ModelContext, appState: AppState) {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        if files.count >= Self.largeBatchThreshold,
           !UserDefaults.standard.bool(forKey: Self.suppressLargeBatchKey) {
            askLargeBatch(count: files.count, appState: appState) { [weak self] proceed in
                if proceed {
                    self?.continueDroppedFiles(files, target: target, groupKey: groupKey, context: context, appState: appState)
                }
            }
            return
        }
        continueDroppedFiles(files, target: target, groupKey: groupKey, context: context, appState: appState)
    }

    private func continueDroppedFiles(_ files: [URL], target: UUID?, groupKey: Int?, context: ModelContext, appState: AppState) {
        let imageCount = files.filter { FileImportService.imageExtensions.contains($0.pathExtension.lowercased()) }.count
        guard imageCount > 0 else {
            enqueueURLs(files, target: target, groupKey: groupKey, imageMode: .ocr, context: context, appState: appState)
            return
        }
        askImageMode(imageCount: imageCount, appState: appState) { [weak self] mode in
            self?.enqueueURLs(files, target: target, groupKey: groupKey, imageMode: mode, context: context, appState: appState)
        }
    }

    // MARK: - Large-batch confirmation

    private struct PendingLargeBatch {
        let count: Int
        let appState: AppState
        let onResolve: (Bool) -> Void   // true = proceed
    }
    private var pendingLargeBatches: [PendingLargeBatch] = []

    func askLargeBatch(count: Int, appState: AppState, onResolve: @escaping (Bool) -> Void) {
        pendingLargeBatches.append(PendingLargeBatch(count: count, appState: appState, onResolve: onResolve))
        showNextLargeBatchPromptIfNeeded()
    }

    private func showNextLargeBatchPromptIfNeeded() {
        guard let batch = pendingLargeBatches.first, batch.appState.largeBatchPrompt == nil else { return }
        batch.appState.largeBatchPrompt = LargeBatchPrompt(fileCount: batch.count)
    }

    /// Called by the dialog. `suppress` persists "Don't Warn Me Again".
    func resolveLargeBatch(proceed: Bool, suppress: Bool) {
        if suppress { UserDefaults.standard.set(true, forKey: Self.suppressLargeBatchKey) }
        guard !pendingLargeBatches.isEmpty else { return }
        let batch = pendingLargeBatches.removeFirst()
        batch.appState.largeBatchPrompt = nil
        batch.onResolve(proceed)
        showNextLargeBatchPromptIfNeeded()
    }

    /// Presents the one-time OCR/Embed prompt for a batch of images and calls
    /// `onResolve` with the user's choice. Used by both Sources and Output drops.
    func askImageMode(imageCount: Int, appState: AppState, onResolve: @escaping (ImageImportMode) -> Void) {
        pendingImageBatches.append(PendingImageBatch(imageCount: imageCount, appState: appState, onResolve: onResolve))
        showNextImagePromptIfNeeded()
    }

    private func showNextImagePromptIfNeeded() {
        guard let batch = pendingImageBatches.first, batch.appState.imageDropPrompt == nil else { return }
        batch.appState.imageDropPrompt = ImageDropPrompt(imageCount: batch.imageCount)
    }

    /// Called by the dialog. nil = cancel the batch.
    func resolveImageChoice(_ mode: ImageImportMode?) {
        guard !pendingImageBatches.isEmpty else { return }
        let batch = pendingImageBatches.removeFirst()
        batch.appState.imageDropPrompt = nil
        if let mode { batch.onResolve(mode) }
        showNextImagePromptIfNeeded()
    }

    /// Enqueue already-extracted items (Share-Extension queue / Dock-icon drops).
    func enqueueItems(_ items: [PendingShareItem], groupKey: Int?, context: ModelContext, appState: AppState) {
        guard !items.isEmpty else { return }
        self.context = context
        self.appState = appState
        queue.append(contentsOf: items.map { .item($0, groupKey: groupKey) })
        pump()
    }

    /// Called when an interactive wizard closes so the next file can be processed.
    func wizardFinished() {
        guard awaitingWizard else { return }
        awaitingWizard = false
        pump()
    }

    private func pump() {
        guard !processing, !awaitingWizard, let context, let appState, !queue.isEmpty else { return }
        processing = true
        let work = queue.removeFirst()

        Task {
            var resolved: PendingShareItem?
            var groupKey: Int?
            switch work {
            case .item(let it, let key):
                resolved = it; groupKey = key
            case .url(let url, let target, let key, let imageMode):
                groupKey = key
                do { resolved = try await FileImportService.makePendingItem(from: url, targetDocumentID: target, imageMode: imageMode) }
                catch { appState.showError("“\(url.lastPathComponent)”: \(error.localizedDescription)") }
            }
            processing = false

            guard var item = resolved else { pump(); return }
            // Group: reuse the document the first file in this batch created.
            if let key = groupKey, let docID = groupDocuments[key] {
                item = item.retargeted(to: docID)
            }
            ShareIntake.consume(item, context: context, appState: appState)
            if let key = groupKey, groupDocuments[key] == nil {
                groupDocuments[key] = appState.selectedDocument?.id
            }
            // Gate on whether consume actually opened a wizard (it sets
            // pendingSourceMethod for audio/video/embed). This is more robust than
            // guessing from the method name — a non-interactive fall-through won't stall.
            if appState.pendingSourceMethod != nil {
                awaitingWizard = true
            } else {
                pump()
            }
        }
    }
}

/// Thin facade the drop targets call. Window drops onto the sidebar create one new
/// document for the whole batch; drops onto a document add to that document. Image
/// files trigger a one-time OCR/Embed prompt for the batch.
@MainActor
enum FileDropImporter {
    static func handleDrop(urls: [URL], into targetDocumentID: UUID?, context: ModelContext, appState: AppState) {
        // A new-document drop (sidebar) groups the batch; a drop onto an existing
        // document targets it directly.
        let groupKey = targetDocumentID == nil ? DropImportCoordinator.shared.newGroupKey() : nil
        DropImportCoordinator.shared.handleDroppedFiles(
            urls, target: targetDocumentID, groupKey: groupKey, context: context, appState: appState)
    }
}

/// Handles files dropped onto the Output editor by inserting their content at the
/// caret: text/PDF/RTF insert their text; images insert OCR text or the picture
/// itself (per the one-time prompt); audio/video can't be inserted inline, so they
/// are added to the document's Sources instead.
@MainActor
enum OutputDropImporter {
    static func handle(urls: [URL], document: TextifyrDocument, inserter: RichTextInserter,
                       context: ModelContext, appState: AppState) {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }

        let images   = files.filter { FileImportService.imageExtensions.contains($0.pathExtension.lowercased()) }
        let nonImage = files.filter { !FileImportService.imageExtensions.contains($0.pathExtension.lowercased()) }

        if !nonImage.isEmpty {
            insertFiles(nonImage, imageMode: .ocr, document: document, inserter: inserter, context: context, appState: appState)
        }
        if !images.isEmpty {
            DropImportCoordinator.shared.askImageMode(imageCount: images.count, appState: appState) { mode in
                insertFiles(images, imageMode: mode, document: document, inserter: inserter, context: context, appState: appState)
            }
        }
    }

    private static func insertFiles(_ urls: [URL], imageMode: ImageImportMode, document: TextifyrDocument,
                                    inserter: RichTextInserter, context: ModelContext, appState: AppState) {
        Task {
            for url in urls {
                let ext = url.pathExtension.lowercased()
                let isImage = FileImportService.imageExtensions.contains(ext)
                let isAV = FileImportService.audioExtensions.contains(ext) || FileImportService.videoExtensions.contains(ext)

                // Audio/video can't be inserted inline — add them as sources instead.
                // Switch to the Sources tab so the transcription wizard is visible
                // (otherwise the serial queue would wait on a wizard that never shows).
                if isAV {
                    NotificationCenter.default.post(name: .requestSourcesTab, object: nil)
                    DropImportCoordinator.shared.handleDroppedFiles(
                        [url], target: document.id, groupKey: nil, context: context, appState: appState)
                    continue
                }

                // Embed a picture directly into the document.
                if isImage, imageMode == .embed {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    if let image = NSImage(contentsOf: url) {
                        inserter.insertImage?(image)
                    } else {
                        appState.showError("Couldn't read “\(url.lastPathComponent)”.")
                    }
                    continue
                }

                // Everything else (text/PDF/RTF, or image OCR) → insert extracted text.
                do {
                    let item = try await FileImportService.makePendingItem(from: url, targetDocumentID: nil, imageMode: .ocr)
                    let text = item.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { inserter.insertText?(text) }
                } catch {
                    appState.showError("“\(url.lastPathComponent)”: \(error.localizedDescription)")
                }
            }
        }
    }
}
