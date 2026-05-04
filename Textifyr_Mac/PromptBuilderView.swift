import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices

// MARK: - Main view

struct PromptBuilderView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \PromptSample.sortOrder) private var allSamples: [PromptSample]

    @State private var promptText: String = ""
    @State private var promptScope: PipelineScope = .source
    @State private var selectedSampleID: UUID? = nil
    @State private var scopeFilter: PipelineScope? = nil

    @State private var isRunning = false
    @State private var runTask: Task<Void, Never>? = nil
    @State private var testResult: String? = nil
    @State private var testError: String? = nil

    @State private var showingLoadSheet = false
    @State private var showingSaveSheet = false

    private static let draftPromptKey = "promptBuilder.draftText"
    private static let draftScopeKey  = "promptBuilder.draftScope"
    private let sampleLimit = 30

    private var filteredSamples: [PromptSample] {
        guard let f = scopeFilter else { return allSamples }
        return allSamples.filter { $0.scope == f }
    }

    private var selectedSample: PromptSample? {
        guard let id = selectedSampleID else { return nil }
        return allSamples.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            promptPanel
            Divider()
            samplesPanel
        }
        .frame(minWidth: 860, minHeight: 580)
        .onAppear { restoreDraft() }
        .onChange(of: promptText)  { _, t in UserDefaults.standard.set(t, forKey: Self.draftPromptKey) }
        .onChange(of: promptScope) { _, s in UserDefaults.standard.set(s.rawValue, forKey: Self.draftScopeKey) }
        .onChange(of: scopeFilter) { _, _ in selectedSampleID = nil }
        .sheet(isPresented: $showingLoadSheet) {
            LoadFromStepSheet { loaded in promptText = loaded }
        }
        .sheet(isPresented: $showingSaveSheet) {
            SaveToPipelineSheet(promptText: promptText, scope: promptScope)
        }
    }

    // MARK: - Prompt panel (left, fixed 320 pt)

    private var promptPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Prompt", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("Pipeline Scope") {
                        Picker("", selection: $promptScope) {
                            ForEach(PipelineScope.allCases, id: \.self) { s in
                                Text(s.displayName).tag(s)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $promptText)
                            .font(.body)
                            .frame(minHeight: 340)
                            .scrollContentBackground(.hidden)
                            .padding(6)

                        if promptText.isEmpty {
                            Text("Enter your prompt here…")
                                .foregroundStyle(.tertiary)
                                .padding(10)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }
                .padding(16)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Load from Step…") { showingLoadSheet = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Button("Clear") { promptText = "" }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(promptText.isEmpty)
                Button("Save to Pipeline…") { showingSaveSheet = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(promptText.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 320)
    }

    // MARK: - Samples panel (right, flex)

    private var samplesPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Samples", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Text("(\(allSamples.count)/\(sampleLimit))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Filter", selection: $scopeFilter) {
                    Text("All Scopes").tag(nil as PipelineScope?)
                    ForEach(PipelineScope.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s as PipelineScope?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)

                Button { addSample() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(allSamples.count >= sampleLimit)
                    .help("Add sample (\(sampleLimit) max)")
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
            .background(.bar)

            Divider()

            HStack(spacing: 0) {
                samplesList
                    .frame(width: 190)
                Divider()
                sampleDetailArea
            }
        }
    }

    private var samplesList: some View {
        List(filteredSamples, id: \.id, selection: $selectedSampleID) { sample in
            SampleRowView(sample: sample)
                .tag(sample.id)
                .contextMenu {
                    Button("Delete", role: .destructive) { deleteSample(sample) }
                }
        }
        .listStyle(.sidebar)
        .onChange(of: selectedSampleID) { _, _ in testResult = nil; testError = nil }
    }

    @ViewBuilder
    private var sampleDetailArea: some View {
        if let sample = selectedSample {
            sampleDetailPanel(sample)
        } else {
            ContentUnavailableView(
                "No Sample Selected",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Select a sample from the list, or tap + to add one.")
            )
        }
    }

    // MARK: - Sample detail panel

    private func sampleDetailPanel(_ sample: PromptSample) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                // Name + scope row
                HStack(spacing: 8) {
                    TextField("Sample name", text: Binding(
                        get: { sample.name },
                        set: { sample.name = $0; try? modelContext.save() }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Picker("", selection: Binding(
                        get: { sample.scope },
                        set: { sample.scope = $0; try? modelContext.save() }
                    )) {
                        ForEach(PipelineScope.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 120)
                }

                Text("Sample Text")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextEditor(text: Binding(
                    get: { sample.sampleText },
                    set: { sample.sampleText = $0; try? modelContext.save() }
                ))
                .font(.body)
                .frame(minHeight: 130, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

                // Run controls
                HStack(spacing: 10) {
                    if isRunning {
                        Button("Cancel") {
                            runTask?.cancel()
                            runTask = nil
                            isRunning = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        ProgressView().controlSize(.small)
                        Text("Running…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            runPrompt(against: sample)
                        } label: {
                            Label("Run Against Sample", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(promptText.isEmpty || sample.sampleText.isEmpty)
                    }
                    Spacer()
                }

                if let err = testError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                // Result
                if let result = testResult {
                    Divider()

                    HStack(alignment: .firstTextBaseline) {
                        Text("Result")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(result, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }

                    Text(result)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(16)
        }
    }

    // MARK: - Actions

    private func addSample() {
        guard allSamples.count < sampleLimit else { return }
        let sample = PromptSample(
            name: "Sample \(allSamples.count + 1)",
            scope: scopeFilter ?? promptScope,
            sortOrder: allSamples.count
        )
        modelContext.insert(sample)
        try? modelContext.save()
        selectedSampleID = sample.id
    }

    private func deleteSample(_ sample: PromptSample) {
        if selectedSampleID == sample.id { selectedSampleID = nil }
        modelContext.delete(sample)
        try? modelContext.save()
    }

    private func runPrompt(against sample: PromptSample) {
        testResult = nil
        testError  = nil
        isRunning  = true
        let prompt     = promptText
        let sampleText = sample.sampleText
        runTask = Task { @MainActor in
            do {
                let result = try await DocumentFormattingService()
                    .formatWithPrompt(sourceText: sampleText, systemPrompt: prompt)
                if !Task.isCancelled { testResult = result }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { testError = error.localizedDescription }
            }
            isRunning = false
            runTask   = nil
        }
    }

    private func restoreDraft() {
        if let t = UserDefaults.standard.string(forKey: Self.draftPromptKey) {
            promptText = t
        }
        if let r = UserDefaults.standard.string(forKey: Self.draftScopeKey),
           let s = PipelineScope(rawValue: r) {
            promptScope = s
        }
    }
}

// MARK: - Sample row

private struct SampleRowView: View {
    let sample: PromptSample

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(sample.name.isEmpty ? "Untitled" : sample.name)
                .font(.callout)
                .lineLimit(1)
            Text(sample.scope.displayName)
                .font(.caption2)
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Load from Step sheet

private struct LoadFromStepSheet: View {
    let onLoad: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FormattingPipeline.name) private var allPipelines: [FormattingPipeline]

    @State private var selectedPipelineID: UUID? = nil
    @State private var selectedStepID: UUID? = nil

    private var selectedPipeline: FormattingPipeline? {
        allPipelines.first { $0.id == selectedPipelineID }
    }
    private var steps: [PipelineStep] { selectedPipeline?.sortedSteps ?? [] }
    private var selectedStep: PipelineStep? {
        steps.first { $0.id == selectedStepID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Load from Step").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            HStack(spacing: 0) {
                // Pipelines
                VStack(alignment: .leading, spacing: 0) {
                    Text("PIPELINE")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    List(allPipelines, id: \.id, selection: $selectedPipelineID) { p in
                        Text(p.name).font(.callout).tag(p.id)
                    }
                    .listStyle(.sidebar)
                    .onChange(of: selectedPipelineID) { _, _ in selectedStepID = nil }
                }
                .frame(width: 200)

                Divider()

                // Steps
                VStack(alignment: .leading, spacing: 0) {
                    Text("STEP")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    if steps.isEmpty {
                        ContentUnavailableView("No Steps", systemImage: "list.bullet")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(steps, id: \.id, selection: $selectedStepID) { step in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.name).font(.callout)
                                Text(step.prompt.prefix(50) + (step.prompt.count > 50 ? "…" : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .tag(step.id)
                        }
                        .listStyle(.sidebar)
                    }
                }
                .frame(width: 220)

                Divider()

                // Prompt preview
                VStack(alignment: .leading, spacing: 8) {
                    Text("PREVIEW")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    if let step = selectedStep {
                        ScrollView {
                            Text(step.prompt)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("Select a step to preview its prompt.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity)
            }

            Divider()

            HStack {
                Spacer()
                Button("Load Prompt") {
                    if let step = selectedStep { onLoad(step.prompt); dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedStep == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 700, height: 420)
    }
}

// MARK: - Save to Pipeline sheet

private struct SaveToPipelineSheet: View {
    let promptText: String
    let scope: PipelineScope
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FormattingPipeline.name) private var allPipelines: [FormattingPipeline]

    enum SaveMode: String, CaseIterable {
        case updateStep   = "Update Existing Step"
        case addStep      = "Add to Pipeline"
        case newPipeline  = "New Pipeline"
    }

    @State private var saveMode: SaveMode = .addStep
    @State private var selectedPipelineID: UUID? = nil
    @State private var selectedStepID: UUID? = nil
    @State private var newPipelineName: String = ""
    @State private var newStepName: String = "Step 1"

    private var scopedPipelines: [FormattingPipeline] {
        allPipelines.filter { $0.scope == scope }
    }
    private var selectedPipeline: FormattingPipeline? {
        allPipelines.first { $0.id == selectedPipelineID }
    }
    private var steps: [PipelineStep] { selectedPipeline?.sortedSteps ?? [] }
    private var selectedStep: PipelineStep? {
        steps.first { $0.id == selectedStepID }
    }
    private var canSave: Bool {
        switch saveMode {
        case .updateStep:  return selectedStep != nil
        case .addStep:     return selectedPipeline != nil && !newStepName.trimmingCharacters(in: .whitespaces).isEmpty
        case .newPipeline: return !newPipelineName.trimmingCharacters(in: .whitespaces).isEmpty
                                  && !newStepName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Save to Pipeline").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $saveMode) {
                    ForEach(SaveMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: saveMode) { _, _ in
                    selectedPipelineID = nil
                    selectedStepID     = nil
                }

                Group {
                    switch saveMode {
                    case .updateStep:  updateStepBody
                    case .addStep:     addStepBody
                    case .newPipeline: newPipelineBody
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)

            Spacer()
            Divider()

            HStack {
                Text(saveModeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save") { performSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 430)
    }

    @ViewBuilder
    private var updateStepBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select the pipeline and step whose prompt to replace.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pipeline (\(scope.displayName))")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    List(scopedPipelines, id: \.id, selection: $selectedPipelineID) { p in
                        Text(p.name).tag(p.id)
                    }
                    .listStyle(.bordered)
                    .onChange(of: selectedPipelineID) { _, _ in selectedStepID = nil }
                }
                .frame(width: 200, height: 180)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Step")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    List(steps, id: \.id, selection: $selectedStepID) { step in
                        Text(step.name).tag(step.id)
                    }
                    .listStyle(.bordered)
                }
                .frame(width: 220, height: 180)
            }
        }
    }

    @ViewBuilder
    private var addStepBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Appends a new step with this prompt to the selected pipeline.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Pipeline (\(scope.displayName))")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                List(scopedPipelines, id: \.id, selection: $selectedPipelineID) { p in
                    Text(p.name).tag(p.id)
                }
                .listStyle(.bordered)
                .frame(height: 150)
            }

            LabeledContent("Step Name") {
                TextField("e.g. Clean Up Filler Words", text: $newStepName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private var newPipelineBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Creates a new \(scope.displayName) pipeline with this prompt as its first step.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Pipeline Name") {
                TextField("e.g. Transcript Cleanup", text: $newPipelineName)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Step Name") {
                TextField("e.g. Remove Filler Words", text: $newStepName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var saveModeHint: String {
        switch saveMode {
        case .updateStep:  return "Replaces the selected step's prompt in place."
        case .addStep:     return "Appends a new step; existing steps are unchanged."
        case .newPipeline: return "Creates a pipeline scoped to \(scope.displayName)."
        }
    }

    private func performSave() {
        switch saveMode {
        case .updateStep:
            guard let step = selectedStep else { return }
            step.prompt = promptText
            try? modelContext.save()

        case .addStep:
            guard let pipeline = selectedPipeline else { return }
            let order = (pipeline.steps ?? []).count
            let step  = PipelineStep(name: newStepName.trimmingCharacters(in: .whitespaces),
                                     prompt: promptText,
                                     sortOrder: order)
            modelContext.insert(step)
            step.pipeline  = pipeline
            pipeline.steps = (pipeline.steps ?? []) + [step]
            try? modelContext.save()

        case .newPipeline:
            let pipeline = FormattingPipeline(
                name: newPipelineName.trimmingCharacters(in: .whitespaces),
                mode: .serial,
                isBuiltIn: false
            )
            pipeline.scope = scope
            modelContext.insert(pipeline)
            let step = PipelineStep(name: newStepName.trimmingCharacters(in: .whitespaces),
                                    prompt: promptText,
                                    sortOrder: 0)
            modelContext.insert(step)
            step.pipeline  = pipeline
            pipeline.steps = [step]
            try? modelContext.save()
        }
        dismiss()
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    return PromptBuilderView()
        .modelContainer(c)
}
