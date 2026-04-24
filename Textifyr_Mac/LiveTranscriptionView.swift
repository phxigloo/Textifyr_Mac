import SwiftUI
import TextifyrViewModels

struct LiveTranscriptionView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch captureVM.phase {
        case .identifySpeakers:
            SpeakerIdentificationView(captureVM: captureVM)
        case .done:
            doneView
        default:
            recordingControls
        }
    }

    // MARK: - Recording controls

    private var recordingControls: some View {
        VStack(spacing: 24) {
            Text("Microphone Recording")
                .font(.title2).bold()
                .padding(.top, 24)

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * CGFloat(captureVM.audioLevel))
                    .animation(.linear(duration: 0.1), value: captureVM.audioLevel)
            }
            .frame(height: 8)
            .background(Color.accentColor.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 40)

            Text(formattedDuration)
                .font(.system(.title, design: .monospaced))
                .foregroundStyle(captureVM.phase == .recording ? .primary : .secondary)

            Toggle("Identify Speakers", isOn: $captureVM.diarizationEnabled)
                .disabled(captureVM.phase != .idle)

            if case .failed(let msg) = captureVM.phase {
                Text(msg).font(.caption).foregroundStyle(.red)
            }

            if captureVM.phase == .transcribing || captureVM.phase == .downloadingModels || captureVM.phase == .diarizing || captureVM.phase == .saving {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(progressLabel).font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                Button("Cancel") {
                    captureVM.reset()
                    dismiss()
                }
                .buttonStyle(.bordered)

                if captureVM.phase == .recording {
                    Button("Stop Recording") {
                        Task { await captureVM.stopMicRecording() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else if captureVM.phase == .idle {
                    Button("Start Recording") {
                        Task { await captureVM.startMicRecording() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 40)
        .frame(width: 480)
    }

    // MARK: - Done

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

    // MARK: - Helpers

    private var formattedDuration: String {
        let t = Int(captureVM.recordingDuration)
        return String(format: "%d:%02d", t / 60, t % 60)
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
