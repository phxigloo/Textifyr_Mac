import SwiftUI
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
                    ExportRow(icon: "doc.fill",        title: "PDF",           detail: "Fixed layout for sharing")        { exportToFile(.pdf) }
                }

                Divider().padding(.vertical, 4)

                Group {
                    ExportRow(icon: "printer",         title: "Print…",        detail: "Print or save as PDF")           { printDocument() }
                    ExportRow(icon: "p.circle",        title: "Open in Pages", detail: "Full editing in Apple Pages")    { openInPages() }
                    if isTableDocument {
                        ExportRow(icon: "n.circle",    title: "Open in Numbers", detail: "Tab-separated data detected")  { openInNumbers() }
                    }
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
        let panel = NSSavePanel()
        let safeName = viewModel.document.title.isEmpty ? "Document" : viewModel.document.title
        panel.nameFieldStringValue = "\(safeName).\(format.rawValue)"
        switch format {
        case .rtf:       panel.allowedContentTypes = [.rtf]
        case .plainText: panel.allowedContentTypes = [.plainText]
        case .markdown:  panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        case .pdf:       panel.allowedContentTypes = [.pdf]
        case .csv:       panel.allowedContentTypes = [.commaSeparatedText]
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
        let attrStr = (try? NSAttributedString(
            data: rtfData,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )) ?? NSAttributedString(string: plainText)

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
            let safeName = viewModel.document.title.isEmpty ? "Document" : viewModel.document.title
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(safeName).rtf")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSWorkspace.shared.open(dest)
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func openInNumbers() {
        do {
            let url = try viewModel.exportFile(format: .csv)
            let safeName = viewModel.document.title.isEmpty ? "Document" : viewModel.document.title
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(safeName).csv")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSWorkspace.shared.open(dest)
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
        } catch {
            exportError = error.localizedDescription
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
