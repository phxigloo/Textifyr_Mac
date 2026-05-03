import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct PipelineDetailView: View {
    @StateObject private var viewModel: PipelineEditorViewModel
    @State private var showWizard = false

    init(pipeline: FormattingPipeline, context: ModelContext) {
        _viewModel = StateObject(wrappedValue: PipelineEditorViewModel(pipeline: pipeline, context: context))
    }

    private var isBuiltIn: Bool { viewModel.pipeline.isBuiltIn }

    private var scopeExplanation: String {
        switch viewModel.pipeline.scope {
        case .postCapture:
            return "Post Capture pipeline — runs automatically after text is acquired from a source. Needs at least 1 step."
        case .source:
            return "Source pipeline — each step receives one session's transcript. Needs at least 1 step."
        case .output:
            return "Output pipeline — each step receives all combined source text. Needs at least 1 step."
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
            // Header: name + mode
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Pipeline name", text: $viewModel.pipelineName)
                        .font(.title2.bold())
                        .textFieldStyle(.plain)
                        .disabled(isBuiltIn)
                        .onSubmit { viewModel.saveName() }

                    Spacer()

                    Picker("", selection: Binding(
                        get: { viewModel.pipeline.mode },
                        set: { newMode in
                            viewModel.pipeline.modeRawValue = newMode.rawValue
                        }
                    )) {
                        ForEach(PipelineMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(isBuiltIn)

                    if !isBuiltIn {
                        Button {
                            showWizard = true
                        } label: {
                            Label("Find Template", systemImage: "sparkles.rectangle.stack")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Find a template matching your goal")
                    }
                }

                // Mode description
                Text(viewModel.pipeline.mode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isBuiltIn {
                    Label("Built-in pipelines cannot be edited. Duplicate to customise.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Scope explanation
                Label(scopeExplanation, systemImage: scopeIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.bar)

            Divider()

            // Step list
            if viewModel.steps.isEmpty {
                ContentUnavailableView(
                    "No Steps",
                    systemImage: "list.bullet",
                    description: Text("Add a step to define what this pipeline does.")
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

                    Spacer()

                    Menu {
                        ForEach(PipelineTemplate.allCases, id: \.templateName) { template in
                            Button(template.templateName) {
                                viewModel.applyTemplate(template)
                            }
                        }
                    } label: {
                        Label("Apply Template", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Replace all steps with a built-in template")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .sheet(isPresented: $showWizard) {
            PipelineWizardView(viewModel: viewModel)
        }
        .navigationTitle(viewModel.pipelineName)
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let pipeline = previewOutputPipeline(in: c)
    return PipelineDetailView(pipeline: pipeline, context: c.mainContext)
        .modelContainer(c)
        .frame(width: 500, height: 500)
}
