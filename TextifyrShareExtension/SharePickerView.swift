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

    enum Phase { case extracting, picking, confirming, done }

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
        .fixedSize(horizontal: false, vertical: true)
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
            ProgressView("Extracting content…")
                .controlSize(.regular)
            if let error = errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding(24)
    }

    // MARK: - Phase: picking

    private var pickingContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let e = extraction {
                previewCard(e)
                    .padding(16)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Add to")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                List(selection: Binding(
                    get: { selectedDocumentID as AnyHashable? },
                    set: { selectedDocumentID = $0 as? UUID }
                )) {
                    Label("New Document", systemImage: "doc.badge.plus")
                        .tag(nil as UUID?)
                    if !recentDocs.isEmpty {
                        Section("Recent") {
                            ForEach(recentDocs) { doc in
                                Label(doc.title, systemImage: "doc.text")
                                    .tag(doc.id as UUID?)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(height: min(44 + CGFloat(recentDocs.count) * 30 + (recentDocs.isEmpty ? 0 : 22), 200))
            }

            Divider()

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

    // MARK: - Phase: confirming (quick spinner while writing queue)

    private var confirmingContent: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Adding…")
        }
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
                Button("Done") { onComplete(nil) }
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
            let item = PendingShareItem(
                captureMethodRaw: e.captureMethodRaw,
                rawText: e.rawText,
                audioFileName: e.audioFileName,
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
