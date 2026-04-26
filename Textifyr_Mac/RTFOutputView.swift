import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TextifyrModels
import TextifyrServices

struct RTFOutputView: View {
    let document: TextifyrDocument
    @StateObject private var formatState = TextFormatState()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Output")
                    .font(.headline)
                Spacer()
                if document.hasOutput {
                    ExportMenuButton(document: document)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if document.hasOutput {
                // Formatting toolbar
                FormattingToolbar(fmt: formatState)

                Divider()

                // Editable rich text view bound to document.outputRTF
                RichTextEditor(
                    rtfData: Binding(
                        get: { document.outputRTF },
                        set: { document.outputRTF = $0 }
                    ),
                    isEditable: true,
                    formatState: formatState
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No formatted output yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Add sources and run the formatting pipeline.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Export menu

private struct ExportMenuButton: View {
    let document: TextifyrDocument

    var body: some View {
        Menu {
            Button("Export as RTF…")        { export(format: .rtf) }
            Button("Export as Plain Text…") { export(format: .plainText) }
            Button("Export as Markdown…")   { export(format: .markdown) }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Export document")
    }

    private func export(format: ExportFormat) {
        do {
            let url = try ExportService.exportFile(
                rtfData: document.outputRTF,
                fallbackText: document.mergedSourceText,
                format: format
            )
            let panel = NSSavePanel()
            panel.nameFieldStringValue = url.lastPathComponent
            let utType: UTType = format == .rtf ? .rtf : format == .markdown ? .text : .plainText
            panel.allowedContentTypes = [utType]
            if panel.runModal() == .OK, let dest = panel.url {
                try? FileManager.default.copyItem(at: url, to: dest)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
