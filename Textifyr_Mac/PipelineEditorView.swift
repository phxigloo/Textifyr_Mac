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
    @State private var activeVM: PipelineEditorViewModel?

    private var selected: FormattingPipeline? {
        pipelines.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(
                    get: { selectedID },
                    set: { newID in
                        selectedID = newID
                        if let id = newID, let p = pipelines.first(where: { $0.id == id }) {
                            activeVM = PipelineEditorViewModel(pipeline: p, context: modelContext)
                        } else {
                            activeVM = nil
                        }
                    }
                )) {
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
                            }
                    }
                }
                .navigationTitle("Pipelines")

                Divider()

                HStack(spacing: 4) {
                    Button { addPipeline() } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("New pipeline")

                    Button {
                        if let p = selected {
                            pipelineToDelete = p
                            showDeleteConfirmation = true
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selected == nil)
                    .help("Delete selected pipeline")

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.bar)
            }
        } detail: {
            if let vm = activeVM {
                PipelineDetailView(viewModel: vm)
                    .id(vm.pipeline.id)
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
        activeVM = PipelineEditorViewModel(pipeline: pipeline, context: modelContext)
    }

    private func deletePipeline(_ pipeline: FormattingPipeline) {
        if selectedID == pipeline.id {
            selectedID = nil
            activeVM = nil
        }
        modelContext.delete(pipeline)
        try? modelContext.save()
    }

    private func duplicate(_ pipeline: FormattingPipeline) {
        let copy = FormattingPipeline(name: pipeline.name + " Copy", mode: pipeline.mode)
        copy.scope = pipeline.scope
        modelContext.insert(copy)
        for step in pipeline.sortedSteps {
            let stepCopy = PipelineStep(name: step.name, prompt: step.prompt, sortOrder: step.sortOrder)
            modelContext.insert(stepCopy)
            stepCopy.pipeline = copy
            copy.steps = (copy.steps ?? []) + [stepCopy]
        }
        try? modelContext.save()
        selectedID = copy.id
        activeVM = PipelineEditorViewModel(pipeline: copy, context: modelContext)
    }
}

// MARK: - List row

struct PipelineListRow: View {
    let pipeline: FormattingPipeline

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(pipeline.name)
                    .font(.body)
                    .strikethrough(pipeline.isHidden, color: .secondary)
                Text("\(pipeline.sortedSteps.count) step\(pipeline.sortedSteps.count == 1 ? "" : "s") · \(pipeline.mode.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .opacity(pipeline.isHidden ? 0.5 : 1)
    }
}

#Preview {
    let c = makePreviewContainer()
    return PipelineEditorView()
        .modelContainer(c)
        .frame(width: 720, height: 540)
}
