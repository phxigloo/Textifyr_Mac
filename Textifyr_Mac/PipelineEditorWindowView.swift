import SwiftUI
import SwiftData
import Combine
import TextifyrModels
import TextifyrViewModels

// MARK: - Window state (chains observation from the active VM)

@MainActor
private final class PipelineWindowState: ObservableObject {
    @Published var activeVM: PipelineEditorViewModel?
    @Published var vmIsDirty = false

    private var dirtyCancellable: AnyCancellable?

    func setVM(_ vm: PipelineEditorViewModel?) {
        dirtyCancellable?.cancel()
        activeVM = vm
        vmIsDirty = false
        dirtyCancellable = vm?.$isDirty
            .receive(on: RunLoop.main)
            .sink { [weak self] dirty in
                guard let self, self.vmIsDirty != dirty else { return }
                Task { @MainActor in self.vmIsDirty = dirty }
            }
    }

    func commitSave() {
        activeVM?.commitSave()
        vmIsDirty = false
    }

    func discardChanges() {
        activeVM?.discardChanges()
        vmIsDirty = false
    }
}

// MARK: - Main view

struct PipelineEditorWindowView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FormattingPipeline.name) private var allPipelines: [FormattingPipeline]

    @StateObject private var windowState = PipelineWindowState()

    @State private var selectedScope: PipelineScope = .output
    @State private var selectedPipelineID: UUID?
    @State private var pendingPipelineID: UUID?
    @State private var showDiscardAlert = false
    @State private var showHidden = false
    @State private var showDeleteConfirmation = false
    @State private var pipelineToDelete: FormattingPipeline?

    private var scopedPipelines: [FormattingPipeline] {
        allPipelines.filter {
            $0.scope == selectedScope && (showHidden || !$0.isHidden)
        }
    }

    private var hasHiddenInScope: Bool {
        allPipelines.contains { $0.scope == selectedScope && $0.isHidden }
    }

    private var selectedPipeline: FormattingPipeline? {
        scopedPipelines.first { $0.id == selectedPipelineID }
    }

    var body: some View {
        NavigationSplitView {
            scopeColumn
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } content: {
            pipelineListColumn
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            detailColumn
                .background(VisualEffectBackground())
        }
        .navigationSplitViewStyle(.prominentDetail)
        .frame(minWidth: 780, minHeight: 520)
        .confirmationDialog("Delete Action", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let p = pipelineToDelete { performDelete(p) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let name = pipelineToDelete?.name ?? "this action"
            Text("Delete \"\(name)\"? This cannot be undone.")
        }
        .confirmationDialog(
            "Unsaved Changes",
            isPresented: $showDiscardAlert,
            titleVisibility: .visible
        ) {
            Button("Save & Switch") {
                windowState.commitSave()
                switchToPipeline(id: pendingPipelineID)
                pendingPipelineID = nil
            }
            Button("Discard & Switch", role: .destructive) {
                windowState.discardChanges()
                switchToPipeline(id: pendingPipelineID)
                pendingPipelineID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingPipelineID = nil
            }
        } message: {
            let name = windowState.activeVM?.pipeline.name ?? "this action"
            Text("Save changes to \"\(name)\" before switching?")
        }
        .onChange(of: selectedScope) { _, _ in
            requestSwitch(to: nil)
        }
    }

    // MARK: - Scope column

    private var scopeColumn: some View {
        List(PipelineScope.allCases, id: \.self, selection: Binding(
            get: { selectedScope },
            set: { newScope in
                if newScope != selectedScope {
                    if windowState.vmIsDirty {
                        pendingPipelineID = nil  // scope change clears pipeline too
                        showDiscardAlert = true
                        // On Save/Discard, selectedScope changes happen in the dialog handler
                        // Use a flag to also switch scope
                    } else {
                        selectedScope = newScope
                        selectedPipelineID = nil
                        Task { @MainActor in windowState.setVM(nil) }
                    }
                }
            }
        )) { scope in
            Label(scope.displayName, systemImage: scopeIcon(scope))
                .tag(scope)
        }
        .navigationTitle("AI Actions")
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Text("PROCESSING STAGE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)
        }
    }

    // MARK: - Pipeline list column

    private var pipelineListColumn: some View {
        VStack(spacing: 0) {
            Text(scopeHint(selectedScope))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            List(selection: pipelineSelectionBinding) {
                ForEach(scopedPipelines) { pipeline in
                    PipelineListRow(pipeline: pipeline)
                        .tag(pipeline.id)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                pipelineToDelete = pipeline
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button("Duplicate") { duplicate(pipeline) }
                            if pipeline.isHidden {
                                Button("Show") { setHidden(false, pipeline: pipeline) }
                            } else {
                                Button("Hide") { setHidden(true, pipeline: pipeline) }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                pipelineToDelete = pipeline
                                showDeleteConfirmation = true
                            }
                        }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.visible)   // opaque sub-master (vs. translucent detail)

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Button {
                        addPipeline()
                    } label: {
                        Image(systemName: "plus").frame(width: 12, height: 12)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("New action")

                    Button {
                        if let p = selectedPipeline {
                            pipelineToDelete = p
                            showDeleteConfirmation = true
                        }
                    } label: {
                        Image(systemName: "minus").frame(width: 12, height: 12)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedPipeline == nil)
                    .help("Delete selected action")

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                if hasHiddenInScope {
                    Divider()
                    Toggle("Show hidden actions", isOn: $showHidden)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .toggleStyle(.checkbox)
                }
            }
            .background(.bar)
        }
        .navigationTitle(selectedScope.displayName)
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if let vm = windowState.activeVM {
            PipelineDetailView(viewModel: vm)
                .id(vm.pipeline.id)
        } else {
            ContentUnavailableView(
                "No Action Selected",
                systemImage: "wand.and.sparkles",
                description: Text("Choose an action from the list, or tap + to create one.")
            )
        }
    }

    // MARK: - Navigation helpers

    private var pipelineSelectionBinding: Binding<UUID?> {
        Binding(
            get: { selectedPipelineID },
            set: { newID in
                guard newID != selectedPipelineID else { return }
                if windowState.vmIsDirty {
                    pendingPipelineID = newID
                    showDiscardAlert = true
                } else {
                    switchToPipeline(id: newID)
                }
            }
        )
    }

    private func requestSwitch(to id: UUID?) {
        if windowState.vmIsDirty {
            pendingPipelineID = id
            showDiscardAlert = true
        } else {
            switchToPipeline(id: id)
        }
    }

    private func switchToPipeline(id: UUID?) {
        selectedPipelineID = id
        let pipelines = allPipelines
        let context = modelContext
        Task { @MainActor in
            if let id, let pipeline = pipelines.first(where: { $0.id == id }) {
                windowState.setVM(PipelineEditorViewModel(pipeline: pipeline, context: context))
            } else {
                windowState.setVM(nil)
            }
        }
    }

    // MARK: - CRUD

    private func addPipeline() {
        let p = FormattingPipeline(name: "New Action")
        p.scope = selectedScope
        modelContext.insert(p)
        try? modelContext.save()
        switchToPipeline(id: p.id)
    }

    private func performDelete(_ pipeline: FormattingPipeline) {
        if selectedPipelineID == pipeline.id {
            switchToPipeline(id: nil)
        }
        modelContext.delete(pipeline)
        try? modelContext.save()
    }

    private func setHidden(_ hidden: Bool, pipeline: FormattingPipeline) {
        pipeline.isHidden = hidden
        try? modelContext.save()
        if hidden, selectedPipelineID == pipeline.id {
            switchToPipeline(id: nil)
        }
    }

    private func duplicate(_ pipeline: FormattingPipeline) {
        let copy = FormattingPipeline(
            name: pipeline.name + " Copy",
            mode: pipeline.mode
        )
        copy.scope = pipeline.scope
        modelContext.insert(copy)
        for step in pipeline.sortedSteps {
            let s = PipelineStep(name: step.name, prompt: step.prompt, sortOrder: step.sortOrder)
            modelContext.insert(s)
            s.pipeline = copy
            copy.steps = (copy.steps ?? []) + [s]
        }
        try? modelContext.save()
        switchToPipeline(id: copy.id)
    }

    // MARK: - Helpers

    private func scopeIcon(_ scope: PipelineScope) -> String {
        switch scope {
        case .postCapture: return "wand.and.sparkles"
        case .source:      return "text.document"
        case .output:      return "doc.on.doc"
        }
    }

    private func scopeHint(_ scope: PipelineScope) -> String {
        switch scope {
        case .postCapture: return "Runs automatically after text is captured from any source."
        case .source:      return "Applied manually to a single source before it is combined with others."
        case .output:      return "Applied to all sources combined to produce the final document."
        }
    }
}

#Preview {
    let c = makePreviewContainer()
    return PipelineEditorWindowView()
        .modelContainer(c)
}
