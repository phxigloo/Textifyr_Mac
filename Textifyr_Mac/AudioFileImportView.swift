import SwiftUI
import UniformTypeIdentifiers
import TextifyrModels
import TextifyrViewModels

struct AudioFileImportView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    let captureMethod: CaptureMethod
    @Environment(\.dismiss) private var dismiss

    @State private var showFileImporter = false

    private static let audioTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie]

    var body: some View {
        switch captureVM.phase {
        case .identifySpeakers:
            SpeakerIdentificationView(captureVM: captureVM)
        case .done:
            doneView
        default:
            importControls
        }
    }

    private var importControls: some View {
        VStack(spacing: 20) {
            Text(captureMethod == .videoAudio ? "Import Video" : "Import Audio File")
                .font(.title2).bold()
                .padding(.top, 24)

            Image(systemName: captureMethod.systemImage)
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            if captureVM.phase == .transcribing || captureVM.phase == .downloadingModels || captureVM.phase == .diarizing || captureVM.phase == .saving {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(progressLabel).font(.caption).foregroundStyle(.secondary)
                }
            } else if case .failed(let msg) = captureVM.phase {
                Text(msg).font(.caption).foregroundStyle(.red)
            } else {
                Toggle("Identify Speakers", isOn: $captureVM.diarizationEnabled)
                    .disabled(captureVM.phase != .idle)

                Button("Choose File…") { showFileImporter = true }
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
            allowedContentTypes: Self.audioTypes,
            allowsMultipleSelection: false
        ) { result in
            guard let url = try? result.get().first else { return }
            Task { await captureVM.processAudioFile(url) }
        }
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Session Added")
                .font(.title2).bold()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .frame(width: 480, height: 220)
    }

    private var progressLabel: String {
        switch captureVM.phase {
        case .transcribing:      return "Transcribing…"
        case .downloadingModels: return "Downloading speaker models (first use only)…"
        case .diarizing:         return "Identifying speakers…"
        case .saving:            return "Saving…"
        default:                 return ""
        }
    }
}
