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
        .confirmationDialog("Delete Pipeline", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
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
            let name = allPipelines.first(where: { $0.id == selectedPipelineID })?.name ?? "this pipeline"
            Text("Delete \"\(name)\"? This cannot be undone.")
        }
        .onDisappear { commitAndClearVM() }
    }

    // MARK: - Header

    private var inspectorHeader: some View {
        HStack {
            Text("Pipelines")
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
            List(filteredPipelines, id: \.id, selection: Binding(
                get: { selectedPipelineID },
                set: { newID in
                    guard newID != selectedPipelineID else { return }
                    commitAndClearVM()
                    selectedPipelineID = newID
                    loadVM(for: newID)
                }
            )) { pipeline in
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
                .contextMenu {
                    if !pipeline.isBuiltIn {
                        Button("Delete", role: .destructive) {
                            selectedPipelineID = pipeline.id
                            showDeleteConfirmation = true
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
                .help("New pipeline")

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
                .help("Delete selected pipeline")

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
            VStack(spacing: 0) {
                HStack {
                    Text(vm.pipeline.name)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Spacer()
                    if !vm.pipeline.isBuiltIn {
                        Button {
                            vm.addStep()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("Add step")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(vm.steps) { step in
                            PipelineStepRow(viewModel: vm, step: step, isLocked: vm.pipeline.isBuiltIn)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Select a pipeline to edit its steps")
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
        let p = FormattingPipeline(name: "New Pipeline")
        p.scope = selectedScope
        modelContext.insert(p)
        try? modelContext.save()
        commitAndClearVM()
        selectedPipelineID = p.id
        loadVM(for: p.id)
    }

    private func scopeLabel(_ scope: PipelineScope) -> String {
        switch scope {
        case .postCapture: return "Auto"
        case .source:      return "Source"
        case .output:      return "Output"
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
