import SwiftUI
import TextifyrModels
import AppKit
import TextifyrViewModels

struct RTFEditorInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Text Editor")
                    .font(.title2).bold()
                Spacer()
                Button("Cancel") {
                    captureVM.reset()
                    dismiss()
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 240)
                .padding(12)

            Divider()

            HStack {
                Spacer()
                Button("Add as Source") {
                    captureVM.saveTextCapture(text, captureMethod: .rtfEditor)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 380)
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { dismiss() }
        }
    }
}
