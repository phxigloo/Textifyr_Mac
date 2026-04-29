import SwiftUI
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct PipelineStepRow: View {
    @ObservedObject var viewModel: PipelineEditorViewModel
    let step: PipelineStep
    let isLocked: Bool

    @State private var name: String
    @State private var prompt: String
    @State private var showImproveSheet = false
    @State private var feedbackText = ""

    private var isImprovingThis: Bool {
        viewModel.isImprovingPrompt && viewModel.improvingStepID == step.id
    }

    init(viewModel: PipelineEditorViewModel, step: PipelineStep, isLocked: Bool = false) {
        self.viewModel = viewModel
        self.step = step
        self.isLocked = isLocked
        _name   = State(initialValue: step.name)
        _prompt = State(initialValue: step.prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row header
            HStack {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .font(.caption)

                TextField("Step name", text: $name)
                    .font(.headline)
                    .textFieldStyle(.plain)
                    .disabled(isLocked)
                    .onSubmit { saveStep() }

                Spacer()

                if !isLocked {
                    Button(role: .destructive) {
                        viewModel.deleteStep(step)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this step")
                }
            }

            // Prompt editor
            Group {
                if isLocked {
                    Text(prompt)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(minHeight: 72, maxHeight: 200)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                        )
                        .onChange(of: prompt) { _, _ in saveStep() }
                }
            }

            // Footer
            if !isLocked {
                HStack {
                    Text("\(prompt.count) / \(AppConstants.maxPromptCharacters) chars")
                        .font(.caption2)
                        .foregroundStyle(prompt.count > AppConstants.maxPromptCharacters ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                    Spacer()
                    if isImprovingThis {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Improving…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            showImproveSheet = true
                        } label: {
                            Label("Improve Prompt", systemImage: "wand.and.stars")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .disabled(viewModel.isImprovingPrompt)
                        .help("Use Apple Intelligence to rewrite this prompt based on your feedback")
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onChange(of: name) { _, _ in saveStep() }
        .onChange(of: step.prompt) { _, newValue in
            // Sync back if AI improvement changed the step in the view model
            if newValue != prompt { prompt = newValue }
        }
        .sheet(isPresented: $showImproveSheet) {
            ImprovePromptSheet(
                feedbackText: $feedbackText,
                isImproving: isImprovingThis,
                onImprove: {
                    let fb = feedbackText
                    showImproveSheet = false
                    feedbackText = ""
                    Task { await viewModel.improvePrompt(step: step, feedback: fb) }
                },
                onCancel: {
                    showImproveSheet = false
                    feedbackText = ""
                }
            )
        }
    }

    private func saveStep() {
        viewModel.updateStep(step, name: name, prompt: prompt)
    }
}

// MARK: - Improve Prompt Sheet

private struct ImprovePromptSheet: View {
    @Binding var feedbackText: String
    let isImproving: Bool
    let onImprove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Improve Prompt")
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("What would you like to improve?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Describe what went wrong with the output, or what you'd like the prompt to do differently. Apple Intelligence will rewrite the prompt for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $feedbackText)
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                    )

                if isImproving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Apple Intelligence is rewriting the prompt…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Improve with AI") {
                    onImprove()
                }
                .buttonStyle(.borderedProminent)
                .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImproving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .frame(width: 420, height: 340)
    }
}
