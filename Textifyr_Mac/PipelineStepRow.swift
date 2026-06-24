import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

struct PipelineStepRow: View {
    @ObservedObject var viewModel: PipelineEditorViewModel
    @EnvironmentObject private var appState: AppState
    let step: PipelineStep
    @State private var name: String
    @State private var prompt: String
    @State private var kind: PipelineStepKind
    @State private var config: TextTransformConfig
    @State private var verify: StepVerifyConfig
    @State private var extract: ExtractFieldsConfig

    private var stepIndex: Int {
        viewModel.steps.firstIndex(where: { $0.id == step.id }) ?? 0
    }

    init(viewModel: PipelineEditorViewModel, step: PipelineStep) {
        self.viewModel = viewModel
        self.step = step
        _name   = State(initialValue: step.name)
        _prompt = State(initialValue: step.prompt)
        _kind   = State(initialValue: step.kind)
        _config = State(initialValue: step.transformConfig)
        _verify = State(initialValue: step.verifyConfig)
        _extract = State(initialValue: step.extractConfig)
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

            switch kind {
            case .aiPrompt:      aiPromptEditor
            case .extractFields: extractFieldsEditor
            case .transform:     transformEditor
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onChange(of: name) { _, _ in saveName() }
        .onChange(of: config) { _, newValue in viewModel.updateStepConfig(step, newValue) }
        .onChange(of: verify) { _, newValue in viewModel.updateStepVerify(step, newValue) }
        .onChange(of: extract) { _, newValue in viewModel.updateStepExtract(step, newValue) }
        .onChange(of: step.prompt) { _, newValue in
            // Sync back if AI improvement changed the step in the view model
            if newValue != prompt { prompt = newValue }
        }
    }

    /// Navigates (in-window, no popup — Phase 22.2) to the Prompt Builder, seeded with
    /// this step's prompt + position. A breadcrumb there leads back to the action.
    private func openInBuilder(improve: Bool) {
        appState.promptBuilderSeed = PromptBuilderSeed(
            prompt: prompt,
            openImprove: improve,
            actionID: viewModel.pipeline.id,
            stepIndex: stepIndex)
        appState.workspaceMode = .promptBuilder
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
        switch newKind {
        case .aiPrompt:
            kind = .aiPrompt
            viewModel.updateStepKind(step, .aiPrompt)
        case .extractFields:
            kind = .extractFields
            viewModel.updateStepKind(step, .extractFields)
            if name.isEmpty || name == "New Step" { name = "Extract Fields" }
        default:
            if let type = newKind.transformType {
                kind = .transform
                config.type = type            // triggers onChange(of: config) → persists
                viewModel.updateStepKind(step, .transform)
                if name.isEmpty || name == "New Step" {
                    name = newKind.label       // triggers onChange(of: name) → persists
                }
            }
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
                    openInBuilder(improve: false)
                } label: {
                    Label("Prompt Builder", systemImage: "text.bubble")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Actions are made of one or more prompts. Use the Prompt Builder to write and test individual prompts before adding them here.")

                Button {
                    openInBuilder(improve: true)
                } label: {
                    Label("Improve Prompt", systemImage: "wand.and.stars")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(prompt.isEmpty)
                .help("Open the Prompt Builder to test this prompt and improve it with AI")
            }

            verifyEditor
        }
    }

    // MARK: - Extract Fields editor (21.1)

    private var extractFieldsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The AI fills these fields, then they're combined deterministically — reliable structured output instead of asking the prompt for delimited text.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach($extract.fields) { $field in
                HStack(spacing: 6) {
                    TextField("Field name", text: $field.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Picker("", selection: $field.type) {
                        ForEach(ExtractFieldType.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("description (optional)", text: $field.fieldDescription)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        extract.fields.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this field")
                }
            }

            Button {
                extract.fields.append(ExtractField())
            } label: {
                Label("Add Field", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Divider()

            HStack(spacing: 8) {
                Text("Combine with:").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $extract.delimiter) {
                    ForEach(ExtractDelimiter.allCases, id: \.self) { d in
                        Text(d.displayName).tag(d)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!extract.template.isEmpty)
                Spacer()
            }

            TextField("Optional template, e.g. {Date}\\t{Payee}\\t{Total}", text: $extract.template)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .help("If set, overrides the delimiter. Use {Field Name} placeholders; \\t = Tab, \\n = newline.")
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
    case extractFields
    case findReplace, delimiter, whitespace, caseTransform, lineOps, homoglyph

    var id: String { rawValue }

    private var isNonTransform: Bool { self == .aiPrompt || self == .extractFields }

    var transformType: TextTransformType? {
        isNonTransform ? nil : TextTransformType(rawValue: rawValue)
    }

    init(kind: PipelineStepKind, type: TextTransformType) {
        switch kind {
        case .aiPrompt:      self = .aiPrompt
        case .extractFields: self = .extractFields
        case .transform:     self = StepUIKind(rawValue: type.rawValue) ?? .findReplace
        }
    }

    var label: String {
        switch self {
        case .aiPrompt:      return "AI Prompt"
        case .extractFields: return "Extract Fields"
        default:             return transformType?.displayName ?? "AI Prompt"
        }
    }

    var icon: String {
        switch self {
        case .aiPrompt:      return "sparkles"
        case .extractFields: return "tablecells"
        default:             return transformType?.icon ?? "sparkles"
        }
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
