import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

/// Sheet-based action editor pre-filtered to one scope, presented **over** a capture wizard so
/// the user can build or edit an action for the current step without losing the in-progress
/// capture (Spec 1). Strictly scope-locked: you only see the actions for the stage you launched
/// from. Self-contained — never touches `workspaceMode`, so the wizard stays mounted behind it.
///
/// `sampleText` carries the captured transcript so the action can be tested against real text
/// (consumed in Spec 2's inline improve panel).
struct ScopedPipelineEditorSheet: View {
    let scope: PipelineScope
    var sampleText: String = ""
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \FormattingPipeline.name) private var allPipelines: [FormattingPipeline]

    @State private var selectedID: UUID?
    @State private var showDeleteConfirmation = false
    @State private var pipelineToDelete: FormattingPipeline?
    @State private var activeVM: PipelineEditorViewModel?
    /// Which step's inline improve panel is open (index into `activeVM.steps`), or nil.
    @State private var improvingStepIndex: Int?
    /// Actions created during this sheet session — removed on Cancel so it truly reverts.
    @State private var createdIDs: Set<UUID> = []

    private var pipelines: [FormattingPipeline] { allPipelines.filter { $0.scope == scope } }

    var body: some View {
        VStack(spacing: 0) {
            // Header — title + one-line scope hint (Done/Cancel now live in the bottom footer).
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(scope.displayName) Actions")
                        .font(.headline)
                    Text(scopeHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            HStack(spacing: 0) {
                // Left: action list + +/- footer
                VStack(spacing: 0) {
                    List(selection: Binding(
                        get: { selectedID },
                        set: { newID in
                            selectedID = newID
                            improvingStepIndex = nil   // panel targets the previous action's steps
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
                    .listStyle(.sidebar)

                    Divider()

                    HStack(spacing: 4) {
                        Button { addPipeline() } label: {
                            Image(systemName: "plus").frame(width: 13, height: 13)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("New action")

                        Button {
                            if let p = pipelines.first(where: { $0.id == selectedID }) {
                                pipelineToDelete = p
                                showDeleteConfirmation = true
                            }
                        } label: {
                            Image(systemName: "minus").frame(width: 13, height: 13)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selectedID == nil)
                        .help("Delete selected action")

                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
                .frame(width: 210)

                Divider()

                // Middle: detail
                Group {
                    if let vm = activeVM {
                        PipelineDetailView(viewModel: vm)
                            .id(vm.pipeline.id)
                    } else {
                        ContentUnavailableView(
                            "No Action Selected",
                            systemImage: "wand.and.sparkles",
                            description: Text("Choose an action or tap + to create one.")
                        )
                    }
                }
                .frame(maxWidth: .infinity)

                // Right: inline test/improve panel (Spec 2), slides in from the trailing edge.
                if let idx = improvingStepIndex, let vm = activeVM {
                    Divider()
                    InlineImprovePanel(
                        viewModel: vm,
                        stepIndex: idx,
                        sampleText: sampleText,
                        onClose: { withAnimation(.easeInOut(duration: 0.22)) { improvingStepIndex = nil } }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            // Footer — matches the wizard chrome (Done/Cancel in a bottom bar, not the header).
            ToolColumnFooter {
                Button("Cancel") { cancelAndDismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Done") { doneAndDismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        // The editor lives over a wizard, so a step's prompt tools must not navigate the main
        // window to the Prompt Builder (that would unmount the wizard). Suppress those buttons and
        // instead let a step open the self-contained inline panel above.
        .environment(\.promptBuilderAvailable, false)
        .environment(\.pipelineCommitsExternally, true)
        .environment(\.inlineImprove) { idx in
            withAnimation(.easeInOut(duration: 0.22)) { improvingStepIndex = idx }
        }
        .frame(width: improvingStepIndex == nil ? 720 : 1060, height: 560)
        .animation(.easeInOut(duration: 0.22), value: improvingStepIndex == nil)
        .confirmationDialog("Delete Action", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let p = pipelineToDelete { deletePipeline(p) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let name = pipelineToDelete?.name ?? "this action"
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

    // MARK: - Commit / revert

    private func doneAndDismiss() {
        try? modelContext.save()   // persist any pending step edits + new/duplicated actions
        dismiss()
    }

    /// Reverts the whole session: discards unsaved step edits (rollback) and removes any actions
    /// created here (they were saved on creation so `+` shows them live, but must not survive a
    /// Cancel). Deletions confirmed via the delete dialog are permanent and are not restored.
    private func cancelAndDismiss() {
        selectedID = nil
        activeVM = nil
        modelContext.rollback()
        for id in createdIDs {
            if let p = allPipelines.first(where: { $0.id == id }) { modelContext.delete(p) }
        }
        try? modelContext.save()
        dismiss()
    }

    // MARK: - List operations

    private func addPipeline() {
        let p = FormattingPipeline(name: "New Action")
        p.scope = scope
        modelContext.insert(p)
        try? modelContext.save()
        createdIDs.insert(p.id)
        selectedID = p.id
        activeVM = PipelineEditorViewModel(pipeline: p, context: modelContext)
    }

    private func deletePipeline(_ pipeline: FormattingPipeline) {
        if selectedID == pipeline.id {
            selectedID = nil
            activeVM = nil
        }
        createdIDs.remove(pipeline.id)
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
        createdIDs.insert(copy.id)
        selectedID = copy.id
        activeVM = PipelineEditorViewModel(pipeline: copy, context: modelContext)
    }
}

#Preview("Source actions sheet") {
    let c = makePreviewContainer()
    return ScopedPipelineEditorSheet(scope: .source)
        .modelContainer(c)
}

#Preview("Output actions sheet") {
    let c = makePreviewContainer()
    return ScopedPipelineEditorSheet(scope: .output)
        .modelContainer(c)
}
