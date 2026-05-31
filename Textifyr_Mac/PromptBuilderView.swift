import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices

// MARK: - Main view

struct PromptBuilderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \PromptSample.sortOrder) private var allSamples: [PromptSample]

    @State private var promptText: String = ""
    @State private var selectedSampleID: UUID? = nil
    @State private var scopeFilter: PipelineScope? = nil

    @State private var isRunning = false
    @State private var runTask: Task<Void, Never>? = nil
    @State private var runProgress: DocumentFormattingService.Progress? = nil
    @State private var testResult: String? = nil
    @State private var testError: String? = nil

    @State private var isImprovingPrompt = false
    @State private var improveTask: Task<Void, Never>? = nil
    @State private var improveError: String? = nil
    @State private var showImprovePopover = false
    @State private var improveFeedbackText = ""

    @State private var showingLoadSheet = false
    @State private var showingSaveSheet = false

    private static let draftPromptKey = "promptBuilder.draftText"
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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                promptPanel
                Divider()
                samplesPanel
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(minWidth: 860, minHeight: 580)
        .onAppear { restoreDraft() }
        .onChange(of: promptText)  { _, t in UserDefaults.standard.set(t, forKey: Self.draftPromptKey) }
        .onChange(of: scopeFilter) { _, _ in selectedSampleID = nil }
        .sheet(isPresented: $showingLoadSheet) {
            LoadFromStepSheet { loaded in promptText = loaded }
        }
        .sheet(isPresented: $showingSaveSheet) {
            SaveToPipelineSheet(promptText: promptText)
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
                VStack(alignment: .leading, spacing: 12) {
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

                    HStack {
                        Spacer()
                        Text("\(promptText.count) / \(AppConstants.maxPromptCharacters) chars")
                            .font(.caption2)
                            .foregroundStyle(promptText.count > AppConstants.maxPromptCharacters
                                ? AnyShapeStyle(.red)
                                : AnyShapeStyle(.tertiary))
                    }

                    HStack(spacing: 8) {
                        if isImprovingPrompt {
                            ProgressView().controlSize(.mini)
                            Text("Improving…").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") {
                                improveTask?.cancel()
                                improveTask = nil
                                isImprovingPrompt = false
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .foregroundStyle(.secondary)
                        } else {
                            if let err = improveError {
                                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1)
                            }
                            Spacer()
                            TranslateButton(
                                helpText: "Insert a translate-to-language prompt into the editor"
                            ) { lang in
                                promptText = lang.promptText
                            }
                            Button {
                                showImprovePopover = true
                            } label: {
                                Label("Improve with AI", systemImage: "wand.and.sparkles")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .disabled(promptText.isEmpty)
                            .popover(isPresented: $showImprovePopover, arrowEdge: .bottom) {
                                ImprovePromptPopover(
                                    feedbackText: $improveFeedbackText,
                                    onImprove: {
                                        let fb = improveFeedbackText
                                        showImprovePopover = false
                                        improveFeedbackText = ""
                                        improvePromptWithAI(feedback: fb)
                                    },
                                    onCancel: {
                                        showImprovePopover = false
                                        improveFeedbackText = ""
                                    }
                                )
                            }
                        }
                    }
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
                Button("Save to Action…") { showingSaveSheet = true }
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
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
            .background(.bar)

            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    samplesList
                    Divider()
                    samplesListControls
                }
                .frame(width: 190)
                Divider()
                sampleDetailArea
            }
        }
    }

    private var samplesList: some View {
        List(selection: $selectedSampleID) {
            ForEach(filteredSamples, id: \.id) { sample in
                SampleRowView(sample: sample)
                    .tag(sample.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteSample(sample)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) { deleteSample(sample) }
                    }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selectedSampleID) { _, _ in testResult = nil; testError = nil }
    }

    private var samplesListControls: some View {
        HStack(spacing: 0) {
            Button {
                addSample()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(allSamples.count >= sampleLimit)
            .help("Add sample (\(sampleLimit) max)")

            Divider().frame(height: 14)

            Button {
                if let s = selectedSample { deleteSample(s) }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 28, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(selectedSample == nil)
            .help("Delete selected sample")

            Spacer()
        }
        .padding(.horizontal, 2)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
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

                TextField("Sample name", text: Binding(
                    get: { sample.name },
                    set: { sample.name = $0; try? modelContext.save() }
                ))
                .textFieldStyle(.roundedBorder)

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

                HStack {
                    Spacer()
                    Text("\(sample.sampleText.count.formatted()) chars")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 10) {
                    if isRunning {
                        Button("Cancel") {
                            runTask?.cancel()
                            runTask = nil
                            isRunning = false
                            runProgress = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        if let p = runProgress, p.chunkCount > 1 {
                            PipelineProgressView(progress: p)
                                .frame(maxWidth: 200)
                        } else {
                            ProgressView().controlSize(.small)
                            Text("Running…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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

                    PromptBuilderResultText(result)
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
            scope: scopeFilter ?? .source,
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
        runProgress = nil
        isRunning  = true
        let prompt     = promptText
        let sampleText = sample.sampleText
        runTask = Task { @MainActor in
            do {
                let result = try await DocumentFormattingService()
                    .formatWithPrompt(sourceText: sampleText, systemPrompt: prompt) { p in
                        runProgress = p
                    }
                if !Task.isCancelled { testResult = result }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { testError = error.localizedDescription }
            }
            isRunning = false
            runProgress = nil
            runTask   = nil
        }
    }

    private func improvePromptWithAI(feedback: String = "") {
        guard !promptText.isEmpty else { return }
        isImprovingPrompt = true
        improveError = nil
        let current = promptText
        let systemPrompt: String
        let trimmedFeedback = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFeedback.isEmpty {
            systemPrompt = "You are an expert prompt engineer. Improve the following AI instruction prompt — make it clearer, more specific, and more effective. Return only the improved prompt text, with no preamble or explanation."
        } else {
            systemPrompt = "You are an expert prompt engineer. Improve the following AI instruction prompt based on this feedback: \"\(trimmedFeedback)\". Return only the improved prompt text, with no preamble or explanation."
        }
        improveTask = Task { @MainActor in
            do {
                let improved = try await DocumentFormattingService()
                    .formatWithPrompt(sourceText: current, systemPrompt: systemPrompt)
                if !Task.isCancelled { promptText = improved }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { improveError = error.localizedDescription }
            }
            isImprovingPrompt = false
            improveTask = nil
        }
    }

    private func restoreDraft() {
        if let t = UserDefaults.standard.string(forKey: Self.draftPromptKey) {
            promptText = t
        }
    }
}

// MARK: - Improve prompt popover

private struct ImprovePromptPopover: View {
    @Binding var feedbackText: String
    let onImprove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Improve Prompt")
                .font(.headline)

            Text("Describe what you'd like to change, or leave blank for a general improvement.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $feedbackText)
                .frame(height: 80)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Improve with AI", action: onImprove)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
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

    @State private var scopeFilter: PipelineScope? = nil
    @State private var selectedPipelineID: UUID? = nil
    @State private var selectedStepID: UUID? = nil

    private var filteredPipelines: [FormattingPipeline] {
        guard let f = scopeFilter else { return allPipelines }
        return allPipelines.filter { $0.scope == f }
    }
    private var selectedPipeline: FormattingPipeline? {
        filteredPipelines.first { $0.id == selectedPipelineID }
    }
    private var steps: [PipelineStep] { selectedPipeline?.sortedSteps ?? [] }
    private var selectedStep: PipelineStep? {
        steps.first { $0.id == selectedStepID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Load from Step").font(.headline)
                Spacer()
                Picker("", selection: $scopeFilter) {
                    Text("All Scopes").tag(nil as PipelineScope?)
                    ForEach(PipelineScope.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s as PipelineScope?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
                .onChange(of: scopeFilter) { _, _ in selectedPipelineID = nil; selectedStepID = nil }
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("ACTION")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    List(filteredPipelines, id: \.id, selection: $selectedPipelineID) { p in
                        Text(p.name).font(.callout).tag(p.id)
                    }
                    .listStyle(.sidebar)
                    .onChange(of: selectedPipelineID) { _, _ in selectedStepID = nil }
                }
                .frame(width: 200)

                Divider()

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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FormattingPipeline.name) private var allPipelines: [FormattingPipeline]

    enum SaveMode: String, CaseIterable {
        case updateStep   = "Update Existing Step"
        case addStep      = "Add to Action"
        case newPipeline  = "New Action"
    }

    @State private var scope: PipelineScope = .source
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
                Text("Save to Action").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                LabeledContent("Scope") {
                    Picker("", selection: $scope) {
                        ForEach(PipelineScope.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 130)
                    .onChange(of: scope) { _, _ in selectedPipelineID = nil; selectedStepID = nil }
                }

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
        .frame(width: 520, height: 460)
    }

    @ViewBuilder
    private var updateStepBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select the action and step whose prompt to replace.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Action (\(scope.displayName))")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    List(scopedPipelines, id: \.id, selection: $selectedPipelineID) { p in
                        Text(p.name).tag(p.id)
                    }
                    .listStyle(.bordered)
                    .onChange(of: selectedPipelineID) { _, _ in selectedStepID = nil }
                }
                .frame(width: 200, height: 160)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Step")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    List(steps, id: \.id, selection: $selectedStepID) { step in
                        Text(step.name).tag(step.id)
                    }
                    .listStyle(.bordered)
                }
                .frame(width: 220, height: 160)
            }
        }
    }

    @ViewBuilder
    private var addStepBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Appends a new step with this prompt to the selected action.")
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
                .frame(height: 130)
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
            Text("Creates a new \(scope.displayName) action with this prompt as its first step.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Action Name") {
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
        case .newPipeline: return "Creates an action scoped to \(scope.displayName)."
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
                mode: .sequential,
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

// MARK: - Markdown-aware result text

private struct PromptBuilderResultText: View {
    let text: String
    init(_ text: String) { self.text = text }

    private var attributedString: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    var body: some View {
        Text(attributedString)
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    return PromptBuilderView()
        .modelContainer(c)
}
