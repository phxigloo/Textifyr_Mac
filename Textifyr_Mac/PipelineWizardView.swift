import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct PipelineWizardView: View {
    @ObservedObject var viewModel: PipelineEditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find a Template")
                        .font(.headline)
                    Text("Describe your goal and we'll suggest a starting point.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.bar)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("e.g. turn meeting recordings into minutes", text: $viewModel.wizardQuery)
                        .textFieldStyle(.plain)
                        .onChange(of: viewModel.wizardQuery) { _, _ in
                            viewModel.updateWizardSuggestions()
                        }
                    if !viewModel.wizardQuery.isEmpty {
                        Button { viewModel.wizardQuery = ""; viewModel.updateWizardSuggestions() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Suggestions
                if viewModel.suggestions.isEmpty {
                    if viewModel.wizardQuery.isEmpty {
                        // Show all templates as browseable list
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Available Templates")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            ForEach(PipelineTemplate.allCases, id: \.templateName) { template in
                                TemplateSuggestionRow(
                                    name: template.templateName,
                                    reason: "\(template.steps.count) step\(template.steps.count == 1 ? "" : "s")",
                                    onApply: {
                                        viewModel.applyTemplate(template)
                                        dismiss()
                                    }
                                )
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 28))
                                .foregroundStyle(.tertiary)
                            Text("No matching templates")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Try different keywords, or apply a template directly from the list below.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Suggestions")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(viewModel.suggestions, id: \.templateName) { suggestion in
                            TemplateSuggestionRow(
                                name: suggestion.templateName,
                                reason: suggestion.reason,
                                onApply: {
                                    viewModel.applyTemplate(suggestion.template)
                                    dismiss()
                                }
                            )
                        }
                    }
                }
            }
            .padding(20)

            Spacer()
        }
        .frame(width: 480, height: 420)
    }
}

// MARK: - Suggestion row

private struct TemplateSuggestionRow: View {
    let name: String
    let reason: String
    let onApply: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body.bold())
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Apply") { onApply() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let vm = previewPipelineVM(in: c)
    return PipelineWizardView(viewModel: vm)
        .modelContainer(c)
        .frame(width: 560, height: 460)
}
