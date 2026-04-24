import SwiftUI
import TextifyrModels
import UniformTypeIdentifiers
import TextifyrViewModels
import TextifyrServices

struct ImageFileImportView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showFileImporter = false
    @State private var isLoading = false
    @State private var errorText: String?

    private static let imageTypes: [UTType] = [.image, .jpeg, .png, .heic, .tiff, .bmp]

    var body: some View {
        VStack(spacing: 20) {
            Text("Import Image")
                .font(.title2).bold()
                .padding(.top, 24)

            Image(systemName: "photo")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if isLoading || captureVM.phase == .saving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Recognising text…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button("Choose Image…") { showFileImporter = true }
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
            allowedContentTypes: Self.imageTypes,
            allowsMultipleSelection: false
        ) { result in
            guard let url = try? result.get().first else { return }
            isLoading = true
            Task {
                do {
                    let text = try await VisionTextService.recognizeText(in: url)
                    captureVM.saveTextCapture(text, captureMethod: .imageFile)
                } catch {
                    errorText = error.localizedDescription
                }
                isLoading = false
            }
        }
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { dismiss() }
        }
    }
}
