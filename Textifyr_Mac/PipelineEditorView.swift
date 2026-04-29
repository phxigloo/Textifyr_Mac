import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct PipelineEditorView: View {
    @Query(sort: \FormattingPipeline.name) private var pipelines: [FormattingPipeline]
    @Environment(\.modelContext) private var modelContext

    @State private var selectedID: UUID?
    @State private var showDeleteConfirmation = false
    @State private var pipelineToDelete: FormattingPipeline?

    private var selected: FormattingPipeline? {
        pipelines.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(pipelines) { pipeline in
                    PipelineListRow(pipeline: pipeline)
                        .tag(pipeline.id)
                        .contextMenu {
                            Button("Duplicate") { duplicate(pipeline) }
                            Divider()
                            Button("Delete", role: .destructive) {
                                pipelineToDelete = pipeline
                                showDeleteConfirmation = true
                            }
                            .disabled(pipeline.isBuiltIn)
                        }
                }
            }
            .navigationTitle("Pipelines")
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    Button { addPipeline() } label: {
                        Image(systemName: "plus")
                    }
                    .help("New pipeline")

                    Button { deleteSelected() } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selected == nil || selected?.isBuiltIn == true)
                    .help("Delete selected pipeline")
                }
            }
        } detail: {
            if let pipeline = selected {
                PipelineDetailView(pipeline: pipeline, context: modelContext)
                    .id(pipeline.id)
            } else {
                ContentUnavailableView(
                    "No Pipeline Selected",
                    systemImage: "wand.and.sparkles",
                    description: Text("Choose a pipeline from the list, or create a new one.")
                )
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .confirmationDialog(
            "Delete Pipeline",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let p = pipelineToDelete { deletePipeline(p) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            let name = pipelineToDelete?.name ?? "this pipeline"
            Text("Delete \"\(name)\"? This cannot be undone.")
        }
    }

    // MARK: - Actions

    private func addPipeline() {
        let pipeline = FormattingPipeline(name: "New Pipeline")
        modelContext.insert(pipeline)
        try? modelContext.save()
        selectedID = pipeline.id
    }

    private func deleteSelected() {
        guard let pipeline = selected, !pipeline.isBuiltIn else { return }
        pipelineToDelete = pipeline
        showDeleteConfirmation = true
    }

    private func deletePipeline(_ pipeline: FormattingPipeline) {
        if selectedID == pipeline.id { selectedID = nil }
        modelContext.delete(pipeline)
        try? modelContext.save()
    }

    private func duplicate(_ pipeline: FormattingPipeline) {
        let copy = FormattingPipeline(name: pipeline.name + " Copy", mode: pipeline.mode, isBuiltIn: false)
        modelContext.insert(copy)
        for step in pipeline.sortedSteps {
            let stepCopy = PipelineStep(name: step.name, prompt: step.prompt, sortOrder: step.sortOrder)
            modelContext.insert(stepCopy)
            stepCopy.pipeline = copy
            copy.steps = (copy.steps ?? []) + [stepCopy]
        }
        try? modelContext.save()
        selectedID = copy.id
    }
}

// MARK: - List row

private struct PipelineListRow: View {
    let pipeline: FormattingPipeline

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(pipeline.name)
                    .font(.body)
                Text("\(pipeline.sortedSteps.count) step\(pipeline.sortedSteps.count == 1 ? "" : "s") · \(pipeline.mode.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if pipeline.isBuiltIn {
                Text("Built-in")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}
