import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

/// Inline pipeline selector for the document header.
/// Shows the selected pipeline name and a dropdown of all pipelines.
/// Includes a "Manage Pipelines…" link that opens the Pipeline Editor window.
struct PipelinePickerView: View {
    @ObservedObject var viewModel: DocumentEditorViewModel
    @Query(sort: \FormattingPipeline.name) private var pipelines: [FormattingPipeline]
    @Environment(\.openWindow) private var openWindow

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
                openWindow(id: "pipeline-editor")
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
