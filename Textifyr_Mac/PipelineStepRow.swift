import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct PipelineStepRow: View {
    @ObservedObject var viewModel: PipelineEditorViewModel
    let step: PipelineStep
    @State private var name: String
    @State private var prompt: String
    @State private var kind: PipelineStepKind
    @State private var config: TextTransformConfig
    @State private var verify: StepVerifyConfig
    @State private var showImproveSheet  = false
    @State private var showPromptBuilder = false
    @State private var feedbackText = ""

    private var isImprovingThis: Bool {
        viewModel.isImprovingPrompt && viewModel.improvingStepID == step.id
    }

    init(viewModel: PipelineEditorViewModel, step: PipelineStep) {
        self.viewModel = viewModel
        self.step = step
        _name   = State(initialValue: step.name)
        _prompt = State(initialValue: step.prompt)
        _kind   = State(initialValue: step.kind)
        _config = State(initialValue: step.transformConfig)
        _verify = State(initialValue: step.verifyConfig)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row header: drag handle, name, type menu, delete
            HStack {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .font(.caption)

                TextField("Step name", text: $name)
                    .font(.headline)
                    .textFieldStyle(.plain)
                    .onSubmit { saveName() }

                Spacer()

                kindMenu

                Button(role: .destructive) {
                    viewModel.deleteStep(step)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete this step")
            }

            if kind == .aiPrompt {
                aiPromptEditor
            } else {
                transformEditor
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onChange(of: name) { _, _ in saveName() }
        .onChange(of: config) { _, newValue in viewModel.updateStepConfig(step, newValue) }
        .onChange(of: verify) { _, newValue in viewModel.updateStepVerify(step, newValue) }
        .onChange(of: step.prompt) { _, newValue in
            // Sync back if AI improvement changed the step in the view model
            if newValue != prompt { prompt = newValue }
        }
        .sheet(isPresented: $showPromptBuilder) {
            PromptBuilderView()
        }
        .sheet(isPresented: $showImproveSheet) {
            ImprovePromptSheet(
                feedbackText: $feedbackText,
                isImproving: isImprovingThis,
                onImprove: {
                    let fb = feedbackText
                    showImproveSheet = false
                    feedbackText = ""
                    Task { await viewModel.improvePrompt(step: step, feedback: fb) }
                },
                onCancel: {
                    showImproveSheet = false
                    feedbackText = ""
                }
            )
        }
    }

    // MARK: - Type menu

    private var currentUIKind: StepUIKind { StepUIKind(kind: kind, type: config.type) }

    private var kindMenu: some View {
        Menu {
            ForEach(StepUIKind.allCases) { k in
                Button { applyUIKind(k) } label: { Label(k.label, systemImage: k.icon) }
            }
        } label: {
            Label(currentUIKind.label, systemImage: currentUIKind.icon)
                .font(.caption)
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose whether this step uses AI or a deterministic text transform")
    }

    private func applyUIKind(_ newKind: StepUIKind) {
        if let type = newKind.transformType {
            kind = .transform
            config.type = type            // triggers onChange(of: config) → persists
            viewModel.updateStepKind(step, .transform)
            if name.isEmpty || name == "New Step" {
                name = newKind.label       // triggers onChange(of: name) → persists
            }
        } else {
            kind = .aiPrompt
            viewModel.updateStepKind(step, .aiPrompt)
        }
    }

    // MARK: - AI prompt editor

    private var aiPromptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 72, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
                .onChange(of: prompt) { _, _ in savePrompt() }

            HStack {
                Text("\(prompt.count) / \(AppConstants.maxPromptCharacters) chars")
                    .font(.caption2)
                    .foregroundStyle(prompt.count > AppConstants.maxPromptCharacters ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                Spacer()
                Button {
                    showPromptBuilder = true
                } label: {
                    Label("Prompt Builder", systemImage: "text.bubble")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Actions are made of one or more prompts. Use the Prompt Builder to write and test individual prompts before adding them here.")

                TranslateButton(helpText: "Replace this step's prompt with a translation instruction") { lang in
                    prompt = lang.promptText
                    savePrompt()
                }

                if isImprovingThis {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Improving…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        showImproveSheet = true
                    } label: {
                        Label("Improve Prompt", systemImage: "wand.and.stars")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isImprovingPrompt)
                    .help("Use Apple Intelligence to rewrite this prompt based on your feedback")
                }
            }

            verifyEditor
        }
    }

    // MARK: - Check & Retry

    private var verifyEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Toggle(isOn: $verify.enabled) {
                Label("Check the result, and retry if it's wrong", systemImage: "checkmark.shield")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)

            if verify.enabled {
                HStack {
                    Text("Check:").font(.caption).foregroundStyle(.secondary)
                    Picker("Check", selection: $verify.check) {
                        ForEach(VerifyCheck.allCases, id: \.self) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                // Parameter for the chosen check
                switch verify.check {
                case .lineColumns:
                    Stepper(value: $verify.expectedColumns, in: 1...20) {
                        Text("Each line has \(verify.expectedColumns) tab-separated column\(verify.expectedColumns == 1 ? "" : "s")")
                            .font(.caption)
                    }
                    .fixedSize()
                case .containsWords:
                    TextField("words, comma-separated", text: $verify.words)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                case .matchesPattern:
                    TextField("regular-expression pattern", text: $verify.pattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                case .notEmpty:
                    EmptyView()
                }

                HStack(spacing: 12) {
                    Stepper(value: $verify.attempts, in: 1...10) {
                        Text("Try up to \(verify.attempts) time\(verify.attempts == 1 ? "" : "s")")
                            .font(.caption)
                    }
                    .fixedSize()

                    Spacer()

                    Text("If it still fails:").font(.caption).foregroundStyle(.secondary)
                    Picker("On failure", selection: $verify.onFailure) {
                        ForEach(VerifyFailureAction.allCases, id: \.self) { a in
                            Text(a.displayName).tag(a)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
        }
    }

    // MARK: - Transform editors

    @ViewBuilder
    private var transformEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(config.type.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch config.type {
            case .findReplace:   findReplaceEditor
            case .delimiter:     delimiterEditor
            case .whitespace:    whitespaceEditor
            case .caseTransform: caseEditor
            case .lineOps:       lineOpsEditor
            case .homoglyph:     EmptyView()
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    private var findReplaceEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Find").font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                TextField(config.useRegex ? "pattern" : "text to find", text: $config.find)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Text("Replace").font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                TextField("replacement", text: $config.replace)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            HStack(spacing: 16) {
                Toggle("Regular expression", isOn: $config.useRegex).toggleStyle(.checkbox)
                Toggle("Case sensitive", isOn: $config.caseSensitive).toggleStyle(.checkbox)
            }
            .font(.caption)
        }
    }

    private var delimiterEditor: some View {
        Picker("Conversion", selection: $config.delimiterPreset) {
            ForEach(DelimiterPreset.allCases, id: \.self) { preset in
                Text(preset.displayName).tag(preset)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private var whitespaceEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Normalize line endings", isOn: $config.normalizeNewlines).toggleStyle(.checkbox)
            Toggle("Trim spaces at the start and end of each line", isOn: $config.trimEachLine).toggleStyle(.checkbox)
            Toggle("Remove trailing spaces", isOn: $config.trimTrailingSpaces).toggleStyle(.checkbox)
                .disabled(config.trimEachLine)
            Toggle("Collapse repeated spaces into one", isOn: $config.collapseSpaces).toggleStyle(.checkbox)
            Toggle("Collapse multiple blank lines into one", isOn: $config.collapseBlankLines).toggleStyle(.checkbox)
        }
        .font(.caption)
    }

    private var caseEditor: some View {
        Picker("Case", selection: $config.caseMode) {
            ForEach(LetterCaseMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var lineOpsEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Remove empty lines", isOn: $config.removeEmptyLines).toggleStyle(.checkbox)
            Toggle("Remove duplicate lines", isOn: $config.dedupeLines).toggleStyle(.checkbox)
            Toggle("Sort lines", isOn: $config.sortLines).toggleStyle(.checkbox)
            Toggle("Sort descending", isOn: $config.sortDescending).toggleStyle(.checkbox)
                .disabled(!config.sortLines)
                .padding(.leading, 16)
            HStack {
                Text("Header row").font(.caption).foregroundStyle(.secondary)
                TextField("optional — type \\t between columns", text: $config.headerText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            .padding(.top, 2)
        }
        .font(.caption)
    }

    // MARK: - Persistence

    private func saveName() {
        viewModel.updateStep(step, name: name, prompt: prompt)
    }

    private func savePrompt() {
        viewModel.updateStep(step, name: name, prompt: prompt)
    }
}

// MARK: - Step UI kind (flattens AI-prompt vs each transform type for the menu)

private enum StepUIKind: String, CaseIterable, Identifiable {
    case aiPrompt
    case findReplace, delimiter, whitespace, caseTransform, lineOps, homoglyph

    var id: String { rawValue }

    var transformType: TextTransformType? {
        self == .aiPrompt ? nil : TextTransformType(rawValue: rawValue)
    }

    init(kind: PipelineStepKind, type: TextTransformType) {
        if kind == .aiPrompt {
            self = .aiPrompt
        } else {
            self = StepUIKind(rawValue: type.rawValue) ?? .findReplace
        }
    }

    var label: String {
        self == .aiPrompt ? "AI Prompt" : (transformType?.displayName ?? "AI Prompt")
    }

    var icon: String {
        self == .aiPrompt ? "sparkles" : (transformType?.icon ?? "sparkles")
    }
}

// MARK: - Improve Prompt Sheet

private struct ImprovePromptSheet: View {
    @Binding var feedbackText: String
    let isImproving: Bool
    let onImprove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Improve Prompt")
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("What would you like to improve?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Describe what went wrong with the output, or what you'd like the prompt to do differently. Apple Intelligence will rewrite the prompt for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $feedbackText)
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                    )

                if isImproving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Apple Intelligence is rewriting the prompt…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Improve with AI") {
                    onImprove()
                }
                .buttonStyle(.borderedProminent)
                .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImproving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .frame(width: 420, height: 340)
    }
}

#Preview { @MainActor in
    let c = makePreviewContainer()
    let vm = previewPipelineVM(in: c)
    let step = vm.steps.first ?? PipelineStep(name: "Format", prompt: "Format this transcript.", sortOrder: 0)
    return List {
        PipelineStepRow(viewModel: vm, step: step)
    }
    .modelContainer(c)
    .frame(width: 480, height: 200)
}
