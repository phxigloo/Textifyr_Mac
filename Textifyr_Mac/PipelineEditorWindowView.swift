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
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FormattingPipeline.name) private var allPipelines: [FormattingPipeline]

    @StateObject private var windowState = PipelineWindowState()

    @State private var selectedScope: PipelineScope = PipelineScope.allCases.first ?? .postCapture
    /// Suppresses default-first-action selection while restoring a specific action (24.3 #1).
    @State private var isRestoringAction = false
    @State private var selectedPipelineID: UUID?
    @State private var pendingPipelineID: UUID?
    @State private var showDiscardAlert = false
    @State private var showHidden = false
    @State private var showDeleteConfirmation = false
    @State private var pipelineToDelete: FormattingPipeline?
    @State private var dropTargetScope: PipelineScope?
    /// Workflows whose stages were cleared because they referenced a just-deleted action.
    @State private var affectedWorkflows: [String] = []
    @State private var showAffectedAlert = false

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
        // Plain HStack of columns (not NavigationSplitView) so the titlebars are flush
        // like the Prompt Builder / Documents — no inset chrome, displacement, or
        // sidebar-toggle button. The dividers between columns match the other tools.
        HStack(spacing: 0) {
            scopeColumn
                .frame(width: 180)
            Divider()
            pipelineListColumn
                .frame(width: 240)
            Divider()
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VisualEffectBackground())
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
        .alert("Workflows Updated", isPresented: $showAffectedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This action was used by \(affectedWorkflows.count) workflow(s): "
                 + affectedWorkflows.joined(separator: ", ")
                 + ". Those stages were cleared so the workflow won't silently skip a missing action.")
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
            // Default-select the first action in the new scope, unless we're restoring a
            // specific one (in which case the restore selects it).
            if !isRestoringAction { requestSwitch(to: scopedPipelines.first?.id) }
            updateBreadcrumb()
        }
        .onChange(of: selectedPipelineID) { _, _ in updateBreadcrumb() }
        .onAppear {
            updateBreadcrumb()
            if appState.actionToOpen != nil {
                openRequestedActionIfNeeded()
            } else if selectedPipelineID == nil {
                requestSwitch(to: scopedPipelines.first?.id)   // default-select the first action
            }
        }
        .onChange(of: appState.actionToOpen) { _, _ in openRequestedActionIfNeeded() }
    }

    /// Kind-aware remedy routing (23.3): when something asks to open a specific action,
    /// switch to its scope and select it.
    private func openRequestedActionIfNeeded() {
        guard let id = appState.actionToOpen else { return }
        appState.actionToOpen = nil
        guard let pipeline = allPipelines.first(where: { $0.id == id }) else { return }
        // Setting the scope fires `onChange(selectedScope)`; the `isRestoringAction` flag stops it
        // from default-selecting the first action, and the deferred `requestSwitch` selects the
        // requested one *after* the scope settles (24.1 bug B).
        isRestoringAction = true
        selectedScope = pipeline.scope
        Task { @MainActor in
            requestSwitch(to: id)
            isRestoringAction = false
        }
    }

    private func updateBreadcrumb() {
        // In an in-context cascade the trail is owned by the drill (24.1) — don't overwrite it.
        guard appState.editOrigin == nil else { return }
        // Standalone/Library authoring: `🧩 Library ▸ <scope> ▸ <action>`.
        var crumbs = appState.rootCrumbs
        crumbs.append(BreadcrumbCrumb(selectedScope.displayName))
        if let p = selectedPipeline { crumbs.append(BreadcrumbCrumb(p.name)) }
        appState.breadcrumb = crumbs
    }

    /// Drop an action onto a scope in the master list to move it to that stage.
    private func handleScopeDrop(_ items: [String], to scope: PipelineScope) -> Bool {
        dropTargetScope = nil
        guard let idString = items.first,
              let id = UUID(uuidString: idString),
              let pipeline = allPipelines.first(where: { $0.id == id }),
              pipeline.scope != scope else { return false }

        // Commit any in-progress edits to the moved action before it leaves the list.
        if windowState.activeVM?.pipeline.id == pipeline.id {
            windowState.commitSave()
        }
        pipeline.scope = scope
        if selectedPipelineID == pipeline.id {
            selectedPipelineID = nil
            Task { @MainActor in windowState.setVM(nil) }
        }
        try? modelContext.save()
        return true
    }

    // MARK: - Scope column

    private var scopeColumn: some View {
        VStack(spacing: 0) {
            ToolColumnHeader("Scopes")

            List(PipelineScope.allCases, id: \.self, selection: Binding(
                get: { selectedScope },
                set: { newScope in
                    if newScope != selectedScope {
                        if windowState.vmIsDirty {
                            pendingPipelineID = nil  // scope change clears pipeline too
                            showDiscardAlert = true
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
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(dropTargetScope == scope ? Color.accentColor.opacity(0.25) : Color.clear)
                    )
                    .dropDestination(for: String.self) { items, _ in
                        handleScopeDrop(items, to: scope)
                    } isTargeted: { targeted in
                        dropTargetScope = targeted ? scope : (dropTargetScope == scope ? nil : dropTargetScope)
                    }
            }
            .listStyle(.inset)
            .modifier(MasterListCard())
        }
        .background(VisualEffectBackground())
        .navigationTitle("AI Actions")
    }

    // MARK: - Pipeline list column

    private var pipelineListColumn: some View {
        VStack(spacing: 0) {
            ToolColumnHeader("Actions")

            Text(scopeHint(selectedScope))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            List(selection: pipelineSelectionBinding) {
                ForEach(scopedPipelines) { pipeline in
                    PipelineListRow(pipeline: pipeline)
                        .tag(pipeline.id)
                        .draggable(pipeline.id.uuidString) {
                            Label(pipeline.name, systemImage: "wand.and.stars")
                                .padding(6)
                        }
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
                            Menu("Move to") {
                                ForEach(PipelineScope.allCases, id: \.self) { target in
                                    Button(target.displayName) {
                                        _ = handleScopeDrop([pipeline.id.uuidString], to: target)
                                    }
                                    .disabled(pipeline.scope == target)
                                }
                            }
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
            .modifier(MasterListCard())

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

                    // Prompt Builder's new home (23.6): reached by drilling into an AI step,
                    // or here for standalone prompt/sample authoring.
                    Button {
                        appState.promptBuilderSeed = nil
                        appState.editOrigin = nil
                        appState.workspaceMode = .promptBuilder
                    } label: {
                        Label("Prompt Builder", systemImage: "text.bubble")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Author and test prompts against samples (no document needed)")
                }
                .padding(.horizontal, 8)
                .frame(height: 34)

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
        .background(VisualEffectBackground())
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
        // Clear any workflow stages that pointed at this action so no workflow is
        // left with a dangling reference it would silently skip when run.
        let affected = WorkflowIntegrity.clearReferences(to: pipeline.id, in: modelContext)
        modelContext.delete(pipeline)
        try? modelContext.save()
        if !affected.isEmpty {
            affectedWorkflows = affected
            showAffectedAlert = true
        }
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
