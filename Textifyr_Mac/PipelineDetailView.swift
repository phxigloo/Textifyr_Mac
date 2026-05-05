import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct PipelineDetailView: View {
    @ObservedObject var viewModel: PipelineEditorViewModel
    @State private var showWizard = false
    @State private var showCopyStep = false

    private var isBuiltIn: Bool { viewModel.pipeline.isBuiltIn }

    private var scopeExplanation: String {
        switch viewModel.pipeline.scope {
        case .postCapture:
            return "Auto Cleanup — runs automatically after text is acquired from a source."
        case .source:
            return "Refine Transcript — each step processes one session's transcript."
        case .output:
            return "Format Document — each step processes all combined source text."
        }
    }

    private var scopeIcon: String {
        switch viewModel.pipeline.scope {
        case .postCapture: return "wand.and.sparkles"
        case .source:      return "text.document"
        case .output:      return "doc.on.doc"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                // Row 1: pipeline name
                HStack(spacing: 8) {
                    TextField("Pipeline name", text: $viewModel.pipelineName)
                        .font(.title2.bold())
                        .textFieldStyle(.plain)
                        .disabled(isBuiltIn)
                        .onSubmit { viewModel.saveName() }
                        .onChange(of: viewModel.pipelineName) { _, _ in viewModel.saveName() }

                    if viewModel.isDirty {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                            .help("Unsaved changes")
                    }
                }

                // Row 2: mode + save/discard
                if !isBuiltIn {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(
                            get: { viewModel.pipeline.mode },
                            set: { newMode in
                                viewModel.pipeline.modeRawValue = newMode.rawValue
                                viewModel.isDirty = true
                            }
                        )) {
                            ForEach(PipelineMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()

                        Spacer()

                        if viewModel.isDirty {
                            Button("Discard") { viewModel.discardChanges() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                            Button("Save") { viewModel.commitSave() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .keyboardShortcut("s", modifiers: .command)
                        }
                    }
                }

                // Row 3: descriptions
                Text(viewModel.pipeline.mode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isBuiltIn {
                    Label("Built-in pipelines cannot be edited. Duplicate to customise.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Label(scopeExplanation, systemImage: scopeIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            // Step list
            if viewModel.steps.isEmpty {
                ContentUnavailableView(
                    "No Steps",
                    systemImage: "list.bullet",
                    description: Text(isBuiltIn
                        ? "Duplicate this pipeline to add steps."
                        : "Tap + to add a step, or use Load Template… to start from a preset.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.steps, id: \.id) { step in
                        PipelineStepRow(viewModel: viewModel, step: step, isLocked: isBuiltIn)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                    .onMove { viewModel.moveSteps(from: $0, to: $1) }
                    .onDelete { offsets in
                        offsets.map { viewModel.steps[$0] }.forEach { viewModel.deleteStep($0) }
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            // Footer
            if !isBuiltIn {
                HStack {
                    Button {
                        viewModel.addStep()
                    } label: {
                        Label("Add Step", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        showWizard = true
                    } label: {
                        Label("Apply Preset…", systemImage: "sparkles.rectangle.stack")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Replace all steps with a built-in preset (Meeting Minutes, Grammar Cleanup, etc.)")

                    Button {
                        showCopyStep = true
                    } label: {
                        Label("Copy Step from Pipeline…", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Browse steps in other pipelines and copy them here")

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .sheet(isPresented: $showWizard) {
            PipelineWizardView(viewModel: viewModel)
        }
        .sheet(isPresented: $showCopyStep) {
            CopyStepSheet(targetViewModel: viewModel)
        }
    }
}

// MARK: - Copy Step Sheet

private struct CopyStepSheet: View {
    @ObservedObject var targetViewModel: PipelineEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FormattingPipeline.name) private var allPipelines: [FormattingPipeline]

    @State private var expandedIDs: Set<UUID> = []

    private var otherPipelines: [FormattingPipeline] {
        allPipelines.filter { $0.id != targetViewModel.pipeline.id && !($0.steps ?? []).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Copy Step from Pipeline")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            if otherPipelines.isEmpty {
                ContentUnavailableView(
                    "No Other Pipelines",
                    systemImage: "doc.on.doc",
                    description: Text("Create additional pipelines to copy steps between them.")
                )
            } else {
                List {
                    ForEach(otherPipelines) { pipeline in
                        Section {
                            if expandedIDs.contains(pipeline.id) {
                                ForEach(pipeline.sortedSteps, id: \.id) { step in
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(step.name).font(.subheadline.weight(.medium))
                                            Text(step.prompt)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                        Button("Copy") {
                                            targetViewModel.copyStep(from: step)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        } header: {
                            Button {
                                if expandedIDs.contains(pipeline.id) {
                                    expandedIDs.remove(pipeline.id)
                                } else {
                                    expandedIDs.insert(pipeline.id)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: expandedIDs.contains(pipeline.id) ? "chevron.down" : "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(pipeline.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("· \(pipeline.scope.displayName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(pipeline.sortedSteps.count) step\(pipeline.sortedSteps.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 520, height: 440)
        .onAppear {
            if let first = otherPipelines.first {
                expandedIDs.insert(first.id)
            }
        }
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let pipeline = previewOutputPipeline(in: c)
    let vm = PipelineEditorViewModel(pipeline: pipeline, context: c.mainContext)
    return PipelineDetailView(viewModel: vm)
        .modelContainer(c)
        .frame(width: 500, height: 500)
}
