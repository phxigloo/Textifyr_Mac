import SwiftUI
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

struct WebInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Import Web Page")
                .font(.title2).bold()
                .padding(.top, 24)

            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            TextField("https://…", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 24)

            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if isLoading || captureVM.phase == .saving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Extracting text…").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                Button("Cancel") {
                    captureVM.reset()
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Import") {
                    importURL()
                }
                .buttonStyle(.borderedProminent)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
            }
            .padding(.bottom, 28)
        }
        .frame(width: 480)
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { dismiss() }
        }
    }

    private func importURL() {
        var raw = urlText.trimmingCharacters(in: .whitespaces)
        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") {
            raw = "https://" + raw
        }
        guard let url = URL(string: raw) else {
            errorText = "Invalid URL"
            return
        }
        errorText = nil
        isLoading = true
        Task {
            do {
                let text = try await WebExtractionService.extractText(from: url)
                captureVM.saveTextCapture(text, captureMethod: .webURL)
            } catch {
                errorText = error.localizedDescription
            }
            isLoading = false
        }
    }
}
