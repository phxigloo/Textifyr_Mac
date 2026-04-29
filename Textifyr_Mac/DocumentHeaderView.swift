import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

struct DocumentHeaderView: View {
    @ObservedObject var viewModel: DocumentEditorViewModel
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState

    @Query(sort: \WorkStage.sortOrder) private var stages: [WorkStage]

    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            TextField("Document title", text: $viewModel.title)
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .onSubmit { viewModel.saveTitle() }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { viewModel.saveTitle() }
                }

            Spacer()

            // Stage picker
            Menu {
                ForEach(stages) { stage in
                    Button {
                        viewModel.selectStage(stage)
                    } label: {
                        Label(stage.name, systemImage: "circle.fill")
                    }
                }
            } label: {
                if let stage = viewModel.document.stage {
                    StageBadgeView(stage: stage)
                } else {
                    Label("Stage", systemImage: "tag")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Pipeline picker
            PipelinePickerView(viewModel: viewModel)

            // Format button
            if viewModel.isFormatting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(viewModel.formattingStep)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Cancel") {
                        viewModel.cancelFormatting(appState: appState)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Button {
                    Task { await viewModel.runFormatting(appState: appState) }
                } label: {
                    Label("Format", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.document.pipeline == nil)
                .help("Run AI formatting pipeline")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .onAppear { assignDefaultStage() }
        .onChange(of: stages) { _, _ in assignDefaultStage() }
    }

    private func assignDefaultStage() {
        guard viewModel.document.stage == nil, let first = stages.first else { return }
        viewModel.selectStage(first)
    }
}
