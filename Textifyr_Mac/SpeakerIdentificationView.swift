import SwiftUI
import TextifyrViewModels
import SwiftData

struct SpeakerIdentificationView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Identify Speakers")
                .font(.title2).bold()
                .padding(.top, 24)

            Text("Optionally rename the detected speakers before AI processing. Leave blank to keep default labels.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(captureVM.detectedSpeakers, id: \.self) { speaker in
                        SpeakerRenameRow(
                            label: speaker,
                            name: Binding(
                                get: { captureVM.speakerNames[speaker] ?? "" },
                                set: { captureVM.speakerNames[speaker] = $0 }
                            )
                        )
                    }
                }
                .padding(.horizontal, 24)
            }
            .frame(maxHeight: 240)

            // Preview
            if !captureVM.mergedDiarizedText.isEmpty {
                GroupBox("Transcript Preview") {
                    ScrollView {
                        Text(String(captureVM.mergedDiarizedText.prefix(400)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 80)
                }
                .padding(.horizontal, 24)
            }

            HStack(spacing: 16) {
                Button("Cancel") {
                    captureVM.reset()
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    captureVM.confirmSpeakers()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 28)
        }
        .frame(width: 480)
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { dismiss() }
        }
    }
}

// MARK: - Speaker rename row

private struct SpeakerRenameRow: View {
    let label: String
    @Binding var name: String

    var body: some View {
        HStack {
            Text(label)
                .font(.body.bold())
                .frame(width: 90, alignment: .leading)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            TextField("Optional name", text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let captureVM = previewCaptureVM(in: c)
    return SpeakerIdentificationView(captureVM: captureVM)
        .modelContainer(c)
        .frame(width: 480, height: 420)
}
