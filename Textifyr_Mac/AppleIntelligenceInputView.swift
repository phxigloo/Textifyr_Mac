import SwiftUI
import TextifyrModels
import TextifyrViewModels
import TextifyrServices
import SwiftData

struct AppleIntelligenceInputView: View {
    @ObservedObject var captureVM: InputCaptureViewModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var aiService = SessionAIService()
    @State private var prompt = ""
    @State private var generatedText = ""
    @State private var isGenerating = false
    @State private var errorText: String?
    @FocusState private var promptFocused: Bool

    private var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    private var hasText: Bool {
        !generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Image(systemName: "wand.and.sparkles")
                    .foregroundStyle(Color.accentColor)
                Text("Apple Intelligence")
                    .font(.title2).bold()
                Spacer()
                Button("Cancel") { captureVM.reset(); dismiss() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Prompt area
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prompt")
                            .font(.headline)
                        TextEditor(text: $prompt)
                            .font(.body)
                            .frame(minHeight: 80, maxHeight: 160)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .focused($promptFocused)

                        HStack {
                            if let error = errorText {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                            Spacer()
                            Button {
                                Task { await generate() }
                            } label: {
                                if isGenerating {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("Generating…")
                                    }
                                } else {
                                    Label(hasText ? "Regenerate" : "Generate", systemImage: "sparkles")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canGenerate)
                        }
                    }

                    // Generated text area
                    if hasText || isGenerating {
                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Generated Text")
                                    .font(.headline)
                                Spacer()
                                if hasText {
                                    Button("Clear") { generatedText = "" }
                                        .buttonStyle(.bordered)
                                        .font(.caption)
                                }
                            }

                            TextEditor(text: $generatedText)
                                .font(.body)
                                .frame(minHeight: 120)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Use as Source") {
                    captureVM.saveTextCapture(generatedText, captureMethod: .appleIntelligence)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasText)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 480)
        .onAppear { promptFocused = true }
        .onChange(of: captureVM.phase) { _, phase in
            if phase == .done { dismiss() }
        }
    }

    private func generate() async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isGenerating = true
        errorText = nil
        generatedText = ""
        do {
            let stream = try await aiService.send(trimmed)
            for await chunk in stream {
                generatedText += chunk
            }
        } catch {
            errorText = error.localizedDescription
        }
        isGenerating = false
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let captureVM = previewCaptureVM(in: c)
    return AppleIntelligenceInputView(captureVM: captureVM)
        .modelContainer(c)
}
