import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

/// Inline output pipeline selector. Shows the selected pipeline name and a dropdown.
/// The "Manage Pipelines…" action is surfaced via a closure so callers can present a sheet.
struct PipelinePickerView: View {
    @ObservedObject var viewModel: DocumentEditorViewModel
    var onManage: (() -> Void)?

    @Query(filter: #Predicate<FormattingPipeline> { $0.scopeRawValue == "output" },
           sort: \FormattingPipeline.name) private var pipelines: [FormattingPipeline]

    var body: some View {
        Menu {
            ForEach(pipelines) { pipeline in
                Button {
                    viewModel.selectPipeline(pipeline)
                } label: {
                    HStack {
                        Text(pipeline.name)
                        if viewModel.document.pipeline?.id == pipeline.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            if !pipelines.isEmpty { Divider() }

            Button {
                onManage?()
            } label: {
                Label("Manage Pipelines…", systemImage: "slider.horizontal.3")
            }
        } label: {
            Label(
                viewModel.document.pipeline?.name ?? "Pipeline",
                systemImage: "wand.and.sparkles"
            )
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Select a formatting pipeline")
    }
}
