import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import TextifyrModels
import TextifyrViewModels

struct AudioFileImportView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    let captureMethod: CaptureMethod
    @Environment(\.dismiss) private var dismiss

    @State private var showFileImporter = false
    @State private var useTimeRange     = false
    @State private var startTimeText    = "0:00"
    @State private var endTimeText      = ""

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

            formatsLabel

            if captureVM.phase == .transcribing || captureVM.phase == .downloadingModels
                || captureVM.phase == .diarizing || captureVM.phase == .saving {
                VStack(spacing: 6) {
                    if captureVM.phase == .transcribing, let fraction = captureVM.transcriptionFraction {
                        ProgressView(value: fraction)
                            .frame(width: 280)
                        Text("\(Int(fraction * 100))% — \(progressLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(progressLabel).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if case .failed(let msg) = captureVM.phase {
                Text(msg).font(.caption).foregroundStyle(.red)
            } else {
                Toggle("Identify Speakers", isOn: $captureVM.diarizationEnabled)
                    .disabled(captureVM.phase != .idle)

                Toggle("Specify time range", isOn: $useTimeRange)
                    .disabled(captureVM.phase != .idle)

                if useTimeRange {
                    timeRangeFields
                }

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
            let range = useTimeRange ? parsedRange() : nil
            Task { await captureVM.processAudioFile(url, range: range) }
        }
    }

    private var formatsLabel: some View {
        VStack(spacing: 2) {
            Text("Audio: MP3 · M4A · WAV · AIFF · FLAC · AAC · CAF")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Video: MP4 · M4V · MOV (QuickTime) · AVI · MKV")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var timeRangeFields: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Start (M:SS)").font(.caption).foregroundStyle(.secondary)
                TextField("0:00", text: $startTimeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("End (M:SS)").font(.caption).foregroundStyle(.secondary)
                TextField("end", text: $endTimeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
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
        case .transcribing:
            if let p = captureVM.chunkProgress {
                return "Transcribing \(p.totalMinutes)-min file…"
            }
            return "Transcribing…"
        case .downloadingModels: return "Downloading speaker models (first use only)…"
        case .diarizing:         return "Identifying speakers…"
        case .saving:            return "Saving…"
        default:                 return ""
        }
    }

    // MARK: - Time parsing

    private func parsedRange() -> ClosedRange<TimeInterval>? {
        let start = parseTime(startTimeText) ?? 0
        guard let end = parseTime(endTimeText), end > start else { return nil }
        return start...end
    }

    private func parseTime(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        switch parts.count {
        case 1:
            guard let s = Double(parts[0]) else { return nil }
            return s
        case 2:
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60 + s
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        default:
            return nil
        }
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let captureVM = previewCaptureVM(in: c)
    return AudioFileImportView(captureVM: captureVM, captureMethod: .audioFile)
        .modelContainer(c)
        .frame(width: 480, height: 420)
}
