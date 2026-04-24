import SwiftUI
import TextifyrModels
import TextifyrViewModels
import TextifyrServices

struct ScreenCaptureInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isCapturing = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Screen Capture")
                .font(.title2).bold()
                .padding(.top, 24)

            Image(systemName: "rectangle.dashed")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("Capture will take a screenshot and extract all visible text.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if let error = errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if isCapturing || captureVM.phase == .saving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Recognising text…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button("Capture Screen") { takeScreenshot() }
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
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { dismiss() }
        }
    }

    private func takeScreenshot() {
        isCapturing = true
        errorText = nil
        Task {
            do {
                let url = try await ScreenCaptureService.captureScreen()
                let text = try await VisionTextService.recognizeText(in: url)
                captureVM.saveTextCapture(text, captureMethod: .screenCapture)
            } catch {
                errorText = error.localizedDescription
            }
            isCapturing = false
        }
    }
}
