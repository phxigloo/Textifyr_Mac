import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct PipelineWizardView: View {
    @ObservedObject var viewModel: PipelineEditorViewModel
    @Environment(\.dismiss) private var dismiss

    private var displayedTemplates: [TemplateItem] {
        if viewModel.wizardQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return PipelineTemplate.allCases.map {
                TemplateItem(
                    name: $0.templateName,
                    detail: "\($0.steps.count) step\($0.steps.count == 1 ? "" : "s") · \($0.scope.displayName)",
                    template: $0
                )
            }
        } else {
            return viewModel.suggestions.map {
                TemplateItem(name: $0.templateName, detail: $0.reason, template: $0.template)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apply Preset")
                        .font(.headline)
                    Text("Replace all steps with a built-in preset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                TextField("Search presets…", text: $viewModel.wizardQuery)
                    .textFieldStyle(.plain)
                    .onChange(of: viewModel.wizardQuery) { _, _ in
                        viewModel.updateWizardSuggestions()
                    }
                if !viewModel.wizardQuery.isEmpty {
                    Button {
                        viewModel.wizardQuery = ""
                        viewModel.updateWizardSuggestions()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Template list
            if displayedTemplates.isEmpty {
                ContentUnavailableView(
                    "No Matching Presets",
                    systemImage: "magnifyingglass",
                    description: Text("Try different keywords.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    let heading = viewModel.wizardQuery.isEmpty ? "All Presets" : "Suggestions"
                    Section(heading) {
                        ForEach(displayedTemplates, id: \.name) { item in
                            HStack(spacing: 12) {
                                Image(systemName: "wand.and.sparkles")
                                    .foregroundStyle(.tint)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.body)
                                    Text(item.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Apply") {
                                    viewModel.applyTemplate(item.template)
                                    dismiss()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 460, height: 400)
    }
}

// MARK: - Helpers

private struct TemplateItem {
    let name: String
    let detail: String
    let template: PipelineTemplate
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let vm = previewPipelineVM(in: c)
    return PipelineWizardView(viewModel: vm)
        .modelContainer(c)
}
