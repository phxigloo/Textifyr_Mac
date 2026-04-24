import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct SettingsView: View {
    private enum Tab: String, CaseIterable {
        case general  = "General"
        case stages   = "Stages"
        case pipelines = "Pipelines"
    }

    @State private var selectedTab: Tab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)

            StagesSettingsView()
                .tabItem { Label("Stages", systemImage: "tag.fill") }
                .tag(Tab.stages)

            PipelinesSettingsView()
                .tabItem { Label("Pipelines", systemImage: "wand.and.sparkles") }
                .tag(Tab.pipelines)
        }
        .frame(width: 560, height: 440)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage(AppConstants.hasAcceptedTermsKey) private var hasAcceptedTerms = true

    var body: some View {
        Form {
            Section("Privacy") {
                LabeledContent("Terms Accepted") {
                    if hasAcceptedTerms {
                        Label("Accepted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not accepted", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Reset and Show Disclaimer") {
                    hasAcceptedTerms = false
                }
                .foregroundStyle(.red)
            }

            Section("iCloud") {
                LabeledContent("Sync Container") {
                    Text(ModelContainerFactory.iCloudContainerIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Stages

private struct StagesSettingsView: View {
    @Query(sort: \WorkStage.sortOrder) private var stages: [WorkStage]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Work Stages")
                .font(.headline)
                .padding(.horizontal)

            List(stages) { stage in
                HStack {
                    StageBadgeView(stage: stage)
                    Spacer()
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
        }
        .padding(.vertical)
    }
}

// MARK: - Pipelines

private struct PipelinesSettingsView: View {
    @Query(sort: \FormattingPipeline.name) private var pipelines: [FormattingPipeline]
    @Environment(\.modelContext) private var modelContext

    @State private var selectedPipeline: FormattingPipeline?
    @State private var showingEditor = false

    var body: some View {
        HSplitView {
            List(pipelines, id: \.id, selection: $selectedPipeline) { pipeline in
                HStack {
                    Text(pipeline.name)
                    Spacer()
                    if pipeline.isBuiltIn {
                        Text("Built-in")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(pipeline.sortedSteps.count) steps")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .tag(pipeline)
                .padding(.vertical, 2)
            }
            .frame(minWidth: 180, idealWidth: 200)

            if let pipeline = selectedPipeline {
                PipelineEditorPane(pipeline: pipeline, context: modelContext)
            } else {
                Text("Select a pipeline to edit")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Pipeline editor pane

private struct PipelineEditorPane: View {
    let pipeline: FormattingPipeline
    @StateObject private var vm: PipelineEditorViewModel

    init(pipeline: FormattingPipeline, context: ModelContext) {
        self.pipeline = pipeline
        _vm = StateObject(wrappedValue: PipelineEditorViewModel(
            pipeline: pipeline,
            context: context
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Pipeline name", text: $vm.pipelineName)
                    .textFieldStyle(.roundedBorder)
                Button("Save Name") { vm.saveName() }
                    .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            List {
                ForEach(vm.steps) { step in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.name).font(.body.bold())
                        Text(step.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { vm.moveSteps(from: $0, to: $1) }
                .onDelete { offsets in
                    offsets.map { vm.steps[$0] }.forEach { vm.deleteStep($0) }
                }
            }
            .listStyle(.plain)

            HStack {
                Button("Add Step") { vm.addStep() }
                    .buttonStyle(.bordered)
                Spacer()
            }
            .padding()
        }
    }
}
