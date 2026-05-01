import SwiftUI
import SwiftData
import AppKit
import TextifyrModels
import TextifyrViewModels

struct RTFEditorInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var formatState = TextFormatState()
    @State private var rtfData: Data? = nil

    private var isEmpty: Bool {
        guard let data = rtfData,
              let attr = NSAttributedString(rtf: data, documentAttributes: nil) else { return true }
        return attr.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Text Editor")
                    .font(.title2).bold()
                Spacer()
                Button("Cancel") { captureVM.reset(); dismiss() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)

            Divider()

            // Formatting toolbar
            FormattingToolbar(fmt: formatState)

            Divider()

            // Rich text editing area
            RichTextEditor(rtfData: $rtfData, isEditable: true, formatState: formatState)
                .frame(minHeight: 220)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Add as Source") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 420)
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { dismiss() }
        }
    }

    private func save() {
        guard let data = rtfData,
              let attr = NSAttributedString(rtf: data, documentAttributes: nil) else { return }
        let plain = attr.string
        captureVM.saveRTFCapture(rtfData: data, plainText: plain)
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let captureVM = previewCaptureVM(in: c)
    return RTFEditorInputView(captureVM: captureVM)
        .modelContainer(c)
}
