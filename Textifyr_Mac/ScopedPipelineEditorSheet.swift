import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

/// Sheet-based pipeline editor pre-filtered to one scope.
/// Kept for backwards compatibility but no longer opened from main UI paths —
/// use the Pipeline Editor window (Tools → Pipeline Editor) instead.
struct ScopedPipelineEditorSheet: View {
    let scope: PipelineScope
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \FormattingPipeline.name) private var allPipelines: [FormattingPipeline]

    @State private var selectedID: UUID?
    @State private var showDeleteConfirmation = false
    @State private var pipelineToDelete: FormattingPipeline?
    @State private var activeVM: PipelineEditorViewModel?

    private var pipelines: [FormattingPipeline] { allPipelines.filter { $0.scope == scope } }

    var body: some View {
        VStack(spacing: 0) {
            // Sheet header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(scope.displayName) Pipelines")
                        .font(.headline)
                    Text(scopeHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    if let vm = activeVM, vm.isDirty { vm.commitSave() }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            HStack(spacing: 0) {
                // Left: pipeline list + +/- footer
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
                                    .disabled(pipeline.isBuiltIn)
                                }
                        }
                    }
                    .listStyle(.sidebar)

                    Divider()

                    HStack(spacing: 4) {
                        Button { addPipeline() } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("New pipeline")

                        Button {
                            if let p = pipelines.first(where: { $0.id == selectedID }) {
                                pipelineToDelete = p
                                showDeleteConfirmation = true
                            }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selectedID == nil || pipelines.first(where: { $0.id == selectedID })?.isBuiltIn == true)
                        .help("Delete selected pipeline")

                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
                .frame(width: 210)

                Divider()

                // Right: detail
                Group {
                    if let vm = activeVM {
                        PipelineDetailView(viewModel: vm)
                            .id(vm.pipeline.id)
                    } else {
                        ContentUnavailableView(
                            "No Pipeline Selected",
                            systemImage: "wand.and.sparkles",
                            description: Text("Choose a pipeline or tap + to create one.")
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 720, height: 540)
        .confirmationDialog("Delete Pipeline", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let p = pipelineToDelete { deletePipeline(p) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let name = pipelineToDelete?.name ?? "this pipeline"
            Text("Delete \"\(name)\"? This cannot be undone.")
        }
    }

    private var scopeHint: String {
        switch scope {
        case .postCapture: return "Runs automatically after text is acquired — no manual trigger needed"
        case .source:      return "Manually applied to refine a single session's transcript while editing"
        case .output:      return "Applied to all sessions combined when formatting the final document"
        }
    }

    private func addPipeline() {
        let p = FormattingPipeline(name: "New Pipeline")
        p.scope = scope
        modelContext.insert(p)
        try? modelContext.save()
        selectedID = p.id
        activeVM = PipelineEditorViewModel(pipeline: p, context: modelContext)
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
        let copy = FormattingPipeline(name: pipeline.name + " Copy", mode: pipeline.mode, isBuiltIn: false)
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

#Preview("Source pipelines sheet") {
    let c = makePreviewContainer()
    return ScopedPipelineEditorSheet(scope: .source)
        .modelContainer(c)
}

#Preview("Output pipelines sheet") {
    let c = makePreviewContainer()
    return ScopedPipelineEditorSheet(scope: .output)
        .modelContainer(c)
}
