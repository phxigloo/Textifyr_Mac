import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrViewModels

struct PipelineInspectorView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @Query(sort: \FormattingPipeline.name) private var allPipelines: [FormattingPipeline]

    @State private var selectedScope: PipelineScope = .output
    @State private var selectedPipelineID: UUID?
    @State private var currentVM: PipelineEditorViewModel?
    @State private var showDeleteConfirmation = false

    private var filteredPipelines: [FormattingPipeline] {
        allPipelines.filter { $0.scope == selectedScope && !$0.isHidden }
    }

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider()
            scopePicker
            Divider()
            pipelineList
            Divider()
            stepsArea
        }
        .confirmationDialog("Delete Action", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = selectedPipelineID,
                   let pipeline = allPipelines.first(where: { $0.id == id }) {
                    commitAndClearVM()
                    selectedPipelineID = nil
                    modelContext.delete(pipeline)
                    try? modelContext.save()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let name = allPipelines.first(where: { $0.id == selectedPipelineID })?.name ?? "this action"
            Text("Delete \"\(name)\"? This cannot be undone.")
        }
        .onDisappear { commitAndClearVM() }
        .onAppear {
            if let scope = appState.inspectorDefaultScope {
                selectedScope = scope
                appState.inspectorDefaultScope = nil
            }
        }
        .onChange(of: appState.inspectorDefaultScope) { _, scope in
            if let scope {
                selectedScope = scope
                appState.inspectorDefaultScope = nil
            }
        }
    }

    // MARK: - Header

    private var inspectorHeader: some View {
        HStack {
            Text("AI Actions")
                .font(.headline)
            Spacer()
            Button {
                appState.showPromptBuilder = true
            } label: {
                Label("Prompt Builder", systemImage: "text.bubble")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Open Prompt Builder to write and test individual prompts")
        }
        .frame(height: 44)
        .padding(.horizontal, 12)
        .background(.bar)
    }

    // MARK: - Scope picker

    private var scopePicker: some View {
        Picker("Scope", selection: $selectedScope) {
            ForEach(PipelineScope.allCases, id: \.self) { scope in
                Text(scopeLabel(scope)).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onChange(of: selectedScope) { _, _ in
            commitAndClearVM()
            selectedPipelineID = nil
        }
    }

    // MARK: - Pipeline list

    private var pipelineList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { selectedPipelineID },
                set: { newID in
                    guard newID != selectedPipelineID else { return }
                    commitAndClearVM()
                    selectedPipelineID = newID
                    loadVM(for: newID)
                }
            )) {
                ForEach(filteredPipelines, id: \.id) { pipeline in
                    HStack {
                        Text(pipeline.name)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                        if pipeline.isBuiltIn {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tag(pipeline.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if !pipeline.isBuiltIn {
                            Button(role: .destructive) {
                                selectedPipelineID = pipeline.id
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .contextMenu {
                        if !pipeline.isBuiltIn {
                            Button("Delete", role: .destructive) {
                                selectedPipelineID = pipeline.id
                                showDeleteConfirmation = true
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(maxHeight: 150)

            Divider()

            HStack(spacing: 6) {
                Button {
                    addPipeline()
                } label: {
                    Image(systemName: "plus").frame(width: 12, height: 12)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("New action")

                Button {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "minus").frame(width: 12, height: 12)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled({
                    guard let id = selectedPipelineID,
                          let p = allPipelines.first(where: { $0.id == id })
                    else { return true }
                    return p.isBuiltIn
                }())
                .help("Delete selected action")

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    // MARK: - Steps area

    @ViewBuilder
    private var stepsArea: some View {
        if let vm = currentVM {
            InspectorStepsView(vm: vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Select an action to edit its steps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    // MARK: - Helpers

    private func loadVM(for id: UUID?) {
        guard let id, let pipeline = allPipelines.first(where: { $0.id == id }) else {
            currentVM = nil
            return
        }
        currentVM = PipelineEditorViewModel(pipeline: pipeline, context: modelContext)
    }

    private func commitAndClearVM() {
        currentVM?.commitSave()
        currentVM = nil
    }

    private func addPipeline() {
        let p = FormattingPipeline(name: "New Action")
        p.scope = selectedScope
        modelContext.insert(p)
        try? modelContext.save()
        commitAndClearVM()
        selectedPipelineID = p.id
        loadVM(for: p.id)
    }

    private func scopeLabel(_ scope: PipelineScope) -> String {
        scope.displayName
    }
}

// MARK: - Steps sub-view (needs @ObservedObject for name editing)

private struct InspectorStepsView: View {
    @ObservedObject var vm: PipelineEditorViewModel
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !vm.pipeline.isBuiltIn {
                    TextField("Action name", text: $vm.pipelineName)
                        .font(.subheadline.bold())
                        .textFieldStyle(.plain)
                        .focused($nameFieldFocused)
                        .onSubmit { vm.saveName() }
                } else {
                    Text(vm.pipeline.name)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                }
                Spacer()
                if !vm.pipeline.isBuiltIn {
                    Button { vm.addStep() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add step")
                    Button("Save") { vm.commitSave() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Save changes")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if vm.steps.isEmpty {
                VStack(spacing: 6) {
                    Text(vm.pipeline.isBuiltIn
                         ? "Duplicate this action to add steps."
                         : "Tap + to add a step.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(vm.steps) { step in
                        PipelineStepRow(viewModel: vm, step: step, isLocked: vm.pipeline.isBuiltIn)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    }
                    .onDelete { offsets in
                        guard !vm.pipeline.isBuiltIn else { return }
                        offsets.map { vm.steps[$0] }.forEach { vm.deleteStep($0) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            if vm.pipelineName == "New Action" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    nameFieldFocused = true
                }
            }
        }
    }
}

#Preview {
    let c = makePreviewContainer()
    return PipelineInspectorView()
        .modelContainer(c)
        .environmentObject(AppState())
        .frame(width: 310, height: 600)
}
