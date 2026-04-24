import SwiftUI
import TextifyrModels
import UniformTypeIdentifiers
import TextifyrViewModels
import TextifyrServices

struct PDFInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showFileImporter = false
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Import PDF")
                .font(.title2).bold()
                .padding(.top, 24)

            Image(systemName: "doc.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if isLoading || captureVM.phase == .saving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Extracting text…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button("Choose PDF…") { showFileImporter = true }
                    .buttonStyle(.borderedProminent)
            }

            Button("Cancel") {
                captureVM.reset()
                dismiss()
            }
            .buttonStyle(.bordered)
            .padding(.bottom, 28)
        }
        .frame(width: 480)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { dismiss() }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let url = try? result.get().first else { return }
        isLoading = true
        errorText = nil
        Task {
            do {
                let text = try PDFTextService.extractText(from: url)
                captureVM.saveTextCapture(text, captureMethod: .pdf)
            } catch {
                errorText = error.localizedDescription
            }
            isLoading = false
        }
    }
}
