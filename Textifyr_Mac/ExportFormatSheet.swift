import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct ExportFormatSheet: View {
    @ObservedObject var viewModel: DocumentEditorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var exportError: String?

    private var plainText: String {
        viewModel.document.outputRTF.flatMap { ExportService.extractPlainText(from: $0) }
            ?? viewModel.document.mergedSourceText
    }

    private var isTableDocument: Bool {
        ExportService.isTableContent(plainText)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Export")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Group {
                    ExportRow(icon: "doc.richtext",   title: "RTF Document",  detail: "Word, Pages compatible")          { exportToFile(.rtf) }
                    ExportRow(icon: "doc.text",        title: "Plain Text",    detail: ".txt — no formatting")            { exportToFile(.plainText) }
                    ExportRow(icon: "chevron.left.forwardslash.chevron.right",
                                                       title: "Markdown",      detail: ".md — Obsidian, Notion, GitHub") { exportToFile(.markdown) }
                    ExportRow(icon: "globe",            title: "HTML",          detail: "Self-contained .html with images") { exportToFile(.html) }
                    ExportRow(icon: "doc.fill",        title: "PDF",           detail: "Fixed layout for sharing")        { exportToFile(.pdf) }
                }

                Divider().padding(.vertical, 4)

                Group {
                    ExportRow(icon: "printer",         title: "Print…",          detail: "Print or save as PDF")              { printDocument() }
                    ExportRow(icon: "p.circle",        title: "Open in Pages",   detail: "Full editing in Apple Pages")       { openInPages() }
                    ExportRow(icon: "n.circle",        title: "Open in Numbers", detail: "Spreadsheet with embedded images")  { openInNumbers() }
                }

                Divider().padding(.vertical, 4)

                ExportRow(icon: "square.and.arrow.up", title: "Share…",        detail: "AirDrop, Mail, and more")        { share() }
            }
            .padding(16)
        }
        .frame(width: 400)
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Actions

    private func exportToFile(_ format: ExportFormat) {
        do {
            let url = try viewModel.exportFile(format: format)
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.runSavePanel(for: url, format: format)
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func runSavePanel(for url: URL, format: ExportFormat) {
        defer { deleteTempFile(url) }
        let panel = NSSavePanel()
        let safeName = viewModel.document.title.isEmpty ? "Document" : viewModel.document.title
        // The produced file may differ from the requested format (e.g. .rtf upgrades to
        // an .rtfd package when it contains images), so key off the real file extension.
        let ext = url.pathExtension.isEmpty ? format.rawValue : url.pathExtension
        panel.nameFieldStringValue = "\(safeName).\(ext)"
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
    }

    private func printDocument() {
        guard let rtfData = viewModel.document.outputRTF else {
            exportError = "No formatted content to print. Run formatting first."
            return
        }
        // Build text + image attachments; NSTextView draws the attachments directly.
        let attrStr = ExportService.attributedStringWithPictures(
            rtfData: rtfData,
            pictureSessions: viewModel.document.sourceSessions ?? []
        )

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(attrStr)

        let printOp = NSPrintOperation(view: textView)
        printOp.printInfo.topMargin    = 36
        printOp.printInfo.bottomMargin = 36
        printOp.printInfo.leftMargin   = 54
        printOp.printInfo.rightMargin  = 54

        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            printOp.run()
        }
    }

    private func openInPages() {
        do {
            let url = try viewModel.exportFile(format: .rtf)
            defer { deleteTempFile(url) }
            let safeName = viewModel.document.title.isEmpty ? "Document" : viewModel.document.title
            let ext  = url.pathExtension.isEmpty ? "rtf" : url.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(safeName).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if let pagesURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages") {
                    NSWorkspace.shared.open([dest], withApplicationAt: pagesURL,
                                           configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                } else {
                    NSWorkspace.shared.open(dest)
                }
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func openInNumbers() {
        do {
            let url = try viewModel.exportFile(format: .xlsx)
            defer { deleteTempFile(url) }
            let safeName = viewModel.document.title.isEmpty ? "Document" : viewModel.document.title
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(safeName).xlsx")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if let numbersURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Numbers") {
                    NSWorkspace.shared.open([dest], withApplicationAt: numbersURL,
                                           configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                } else {
                    NSWorkspace.shared.open(dest)
                }
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func share() {
        do {
            let url = try viewModel.exportFile(format: .rtf)
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let anchor = NSApp.keyWindow?.contentView else { return }
                let picker = NSSharingServicePicker(items: [url])
                picker.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
            }
            // Share sheet reads the file asynchronously; delete after 2 min to cover all services.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Temp file cleanup

    private func deleteTempFile(_ url: URL) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Row component

private struct ExportRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let vm = previewDocumentVM(in: c)
    return ExportFormatSheet(viewModel: vm)
        .modelContainer(c)
}
