import SwiftUI
import SwiftData
import AppKit
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

// MARK: - Root

struct SettingsView: View {
    private enum Tab: Hashable {
        case general, textProcessing, stages, pipelines
    }
    @State private var selectedTab: Tab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralTab()
                .tabItem { Label("General",         systemImage: "gearshape") }
                .tag(Tab.general)

            TextProcessingTab()
                .tabItem { Label("Text Processing", systemImage: "text.justify.left") }
                .tag(Tab.textProcessing)

            StagesTab()
                .tabItem { Label("Stages",          systemImage: "tag.fill") }
                .tag(Tab.stages)

            PipelinesTab()
                .tabItem { Label("Pipelines",       systemImage: "wand.and.sparkles") }
                .tag(Tab.pipelines)
        }
        .frame(minWidth: 740, minHeight: 520)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @AppStorage(AppConstants.hasAcceptedTermsKey)         private var hasAcceptedTerms        = true
    @AppStorage(AppConstants.hasShownAIPrivacyWarningKey) private var hasShownAIPrivacyWarning = false
    @AppStorage(AppConstants.localProcessingOnlyKey)      private var localProcessingOnly      = false
    @AppStorage(AppConstants.maxDocumentWindowsKey)       private var maxDocumentWindows       = AppConstants.defaultMaxDocumentWindows
    @State private var showPrivacyPolicy = false

    var body: some View {
        Form {
            Section("Apple Intelligence") {
                LabeledContent("Processing") {
                    Text("On-device or Apple Private Cloud Compute")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Data retention") {
                    Text("Apple does not store your data")
                        .foregroundStyle(.secondary)
                }
                Button("Show AI Privacy Notice Again") {
                    hasShownAIPrivacyWarning = false
                }
                .help("The privacy notice will appear before your next AI operation")
            }

            Section("Network") {
                Toggle("Block web requests", isOn: $localProcessingOnly)
                Text("When enabled, the Web URL source cannot fetch pages. All other capture methods remain available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Document Windows") {
                Stepper(value: $maxDocumentWindows, in: 1...10) {
                    LabeledContent("Maximum open documents") {
                        Text("\(maxDocumentWindows)")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Limits how many document windows can be open at once. Existing windows are not closed when you lower this value.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Terms & Privacy") {
                LabeledContent("Terms accepted") {
                    if hasAcceptedTerms {
                        Label("Accepted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not accepted", systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                }
                Button("View Privacy Policy") {
                    showPrivacyPolicy = true
                }
                .sheet(isPresented: $showPrivacyPolicy) {
                    PrivacyPolicyView()
                }
                Button("Reset and Show Disclaimer") {
                    hasAcceptedTerms = false
                }
                .foregroundStyle(.red)
                .help("Clears acceptance and shows the disclaimer on next launch")
            }

            Section("iCloud") {
                LabeledContent("Sync container") {
                    Text(ModelContainerFactory.iCloudContainerIdentifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Text Processing

private struct CleanupRule: Identifiable {
    let id = UUID()
    var find: String
    var replace: String
}

private struct TextProcessingTab: View {
    @AppStorage(AppConstants.postProcessingEnabledKey) private var postProcessingEnabled = true
    @Query(sort: \FormattingPipeline.name) private var pipelines: [FormattingPipeline]

    @State private var customFillerWords: [String] = []
    @State private var cleanupRules: [CleanupRule] = []
    @State private var newFillerWord = ""
    @State private var newFind       = ""
    @State private var newReplace    = ""
    @State private var defaultPipelineID = ""

    var body: some View {
        Form {
            Section("Auto-Cleanup") {
                Toggle("Apply post-processing on import", isOn: $postProcessingEnabled)
                Text("Removes filler words, normalises punctuation, and applies find/replace rules when text is captured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Filler Words") {
                DisclosureGroup("Built-in words (\(AppConstants.defaultFillerWords.count))") {
                    Text(AppConstants.defaultFillerWords.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !customFillerWords.isEmpty {
                    ForEach(customFillerWords, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button {
                                customFillerWords.removeAll { $0 == word }
                                saveFillerWords()
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                HStack {
                    TextField("Add filler word…", text: $newFillerWord)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addFillerWord() }
                    Button("Add") { addFillerWord() }
                        .disabled(newFillerWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Find & Replace Rules") {
                if cleanupRules.isEmpty {
                    Text("No rules — text is left as-is after filler removal.")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                ForEach(cleanupRules) { rule in
                    HStack(spacing: 8) {
                        Text(rule.find)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Group {
                            if rule.replace.isEmpty {
                                Text("(remove)").foregroundStyle(.tertiary)
                            } else {
                                Text(rule.replace)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            cleanupRules.removeAll { $0.id == rule.id }
                            saveCleanupRules()
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack(spacing: 8) {
                    TextField("Find…", text: $newFind).textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
                    TextField("Replace with…", text: $newReplace).textFieldStyle(.roundedBorder)
                    Button("Add") { addCleanupRule() }
                        .disabled(newFind.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Default Output Pipeline") {
                Picker("New document pipeline", selection: $defaultPipelineID) {
                    Text("None").tag("")
                    ForEach(pipelines.filter { $0.scope == .output }) { pipeline in
                        Text(pipeline.name).tag(pipeline.id.uuidString)
                    }
                }
                .onChange(of: defaultPipelineID) { _, id in
                    UserDefaults.standard.set(id, forKey: AppConstants.defaultPipelineIDKey)
                }
                Text("Applied automatically when a new document is created.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { loadSettings() }
    }

    private func addFillerWord() {
        let word = newFillerWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !customFillerWords.contains(word) else { return }
        customFillerWords.append(word)
        newFillerWord = ""
        saveFillerWords()
    }

    private func saveFillerWords() {
        UserDefaults.standard.set(customFillerWords, forKey: AppConstants.customFillerWordsKey)
    }

    private func addCleanupRule() {
        let find = newFind.trimmingCharacters(in: .whitespaces)
        guard !find.isEmpty else { return }
        cleanupRules.append(CleanupRule(find: find, replace: newReplace))
        newFind = ""; newReplace = ""
        saveCleanupRules()
    }

    private func saveCleanupRules() {
        let raw = cleanupRules.map { ["find": $0.find, "replace": $0.replace] }
        UserDefaults.standard.set(raw, forKey: AppConstants.cleanupRulesKey)
    }

    private func loadSettings() {
        customFillerWords = UserDefaults.standard.array(forKey: AppConstants.customFillerWordsKey) as? [String] ?? []
        let raw = UserDefaults.standard.array(forKey: AppConstants.cleanupRulesKey) as? [[String: String]] ?? []
        cleanupRules = raw.compactMap { dict in
            guard let find = dict["find"] else { return nil }
            return CleanupRule(find: find, replace: dict["replace"] ?? "")
        }
        defaultPipelineID = UserDefaults.standard.string(forKey: AppConstants.defaultPipelineIDKey) ?? ""
    }
}

// MARK: - Stages

private struct StagesTab: View {
    @Query(sort: \WorkStage.sortOrder) private var stages: [WorkStage]
    @Environment(\.modelContext) private var modelContext

    @State private var editingStage: WorkStage?
    @State private var showAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(stages) { stage in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                        StageBadgeView(stage: stage)
                        Spacer()
                        Button("Edit") { editingStage = stage }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        Button(role: .destructive) { deleteStage(stage) } label: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { reorder(from: $0, to: $1) }
            }
            .listStyle(.plain)

            Divider()

            HStack {
                Button { showAddSheet = true } label: {
                    Label("Add Stage", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Text("Drag to reorder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .sheet(item: $editingStage) { stage in
            StageEditorSheet(stage: stage, context: modelContext)
        }
        .sheet(isPresented: $showAddSheet) {
            StageEditorSheet(stage: nil, context: modelContext)
        }
    }

    private func deleteStage(_ stage: WorkStage) {
        modelContext.delete(stage)
        try? modelContext.save()
    }

    private func reorder(from offsets: IndexSet, to destination: Int) {
        var reordered = stages
        reordered.move(fromOffsets: offsets, toOffset: destination)
        for (i, stage) in reordered.enumerated() { stage.sortOrder = i }
        try? modelContext.save()
    }
}

// MARK: - Stage editor sheet

private struct StageEditorSheet: View {
    let stage: WorkStage?
    let context: ModelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var bgColor: Color
    @State private var textColor: Color

    init(stage: WorkStage?, context: ModelContext) {
        self.stage = stage
        self.context = context
        _name      = State(initialValue: stage?.name ?? "New Stage")
        _bgColor   = State(initialValue: stage?.color ?? .blue)
        _textColor = State(initialValue: stage?.textColor ?? .white)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(stage == nil ? "New Stage" : "Edit Stage").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            Form {
                Section {
                    TextField("Stage name", text: $name)
                    ColorPicker("Background colour", selection: $bgColor, supportsOpacity: false)
                    ColorPicker("Text colour", selection: $textColor, supportsOpacity: false)
                    LabeledContent("Preview") {
                        Text(name.isEmpty ? "Stage" : name)
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(bgColor)
                            .foregroundStyle(textColor)
                            .clipShape(Capsule())
                    }
                }
            }
            .formStyle(.grouped)
            .padding()

            Divider()

            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .frame(width: 380)
    }

    private func save() {
        let bgHex   = colorToHex(bgColor)
        let textHex = colorToHex(textColor)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let stage {
            stage.name = trimmed
            stage.colorHex = bgHex
            stage.textColorHex = textHex
        } else {
            let count = (try? context.fetch(FetchDescriptor<WorkStage>()))?.count ?? 0
            let newStage = WorkStage(name: trimmed, colorHex: bgHex, textColorHex: textHex, sortOrder: count)
            context.insert(newStage)
        }
        try? context.save()
        dismiss()
    }

    private func colorToHex(_ color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        nsColor.getRed(&r, green: &g, blue: &b, alpha: nil)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Pipelines

private struct PipelinesTab: View {
    @Query(sort: \FormattingPipeline.name) private var allPipelines: [FormattingPipeline]
    @Environment(\.modelContext) private var modelContext

    @State private var scope: PipelineScope = .output
    @State private var selectedID: UUID?
    @State private var showDeleteConfirmation = false
    @State private var pipelineToDelete: FormattingPipeline?

    private var pipelines: [FormattingPipeline] { allPipelines.filter { $0.scope == scope } }
    private var selected: FormattingPipeline? { pipelines.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            // Scope selector + explanation
            HStack(spacing: 12) {
                Picker("", selection: $scope) {
                    ForEach(PipelineScope.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Text(scopeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            HStack(spacing: 0) {
                // Left: list + +/- footer
                VStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(pipelines) { pipeline in
                            PipelineListRow(pipeline: pipeline)
                                .tag(pipeline.id)
                                .contextMenu {
                                    Button("Duplicate") { duplicate(pipeline) }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        pipelineToDelete = pipeline
                                        showDeleteConfirmation = true
                                    }
                                    .disabled(pipeline.isBuiltIn)
                                }
                        }
                    }
                    .listStyle(.sidebar)

                    Divider()

                    HStack(spacing: 2) {
                        Button { addPipeline() } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("New pipeline")
                        Button {
                            if let p = selected {
                                pipelineToDelete = p
                                showDeleteConfirmation = true
                            }
                        } label: { Image(systemName: "minus") }
                            .buttonStyle(.borderless)
                            .disabled(selected == nil || selected?.isBuiltIn == true)
                            .help("Delete selected pipeline")
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
                .frame(width: 210)

                Divider()

                // Right: detail
                Group {
                    if let pipeline = selected {
                        PipelineDetailView(pipeline: pipeline, context: modelContext)
                            .id(pipeline.id)
                    } else {
                        ContentUnavailableView(
                            "No Pipeline Selected",
                            systemImage: "wand.and.sparkles",
                            description: Text("Choose a pipeline or tap + to create one.")
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .confirmationDialog("Delete Pipeline", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let p = pipelineToDelete { deletePipeline(p) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let name = pipelineToDelete?.name ?? "this pipeline"
            Text("Delete \"\(name)\"? This cannot be undone.")
        }
        .onChange(of: scope) { _, _ in selectedID = nil }
    }

    private var scopeHint: String {
        switch scope {
        case .postCapture: return "Runs automatically after text is acquired — select in source wizards"
        case .source:      return "Runs on an individual session's transcript · needs at least 1 step"
        case .output:      return "Runs on all combined sources · needs at least 1 step"
        }
    }

    private func addPipeline() {
        let p = FormattingPipeline(name: "New Pipeline")
        p.scope = scope
        modelContext.insert(p)
        try? modelContext.save()
        selectedID = p.id
    }

    private func deletePipeline(_ pipeline: FormattingPipeline) {
        if selectedID == pipeline.id { selectedID = nil }
        modelContext.delete(pipeline)
        try? modelContext.save()
    }

    private func duplicate(_ pipeline: FormattingPipeline) {
        let copy = FormattingPipeline(name: pipeline.name + " Copy", mode: pipeline.mode, isBuiltIn: false)
        copy.scope = pipeline.scope
        modelContext.insert(copy)
        for step in pipeline.sortedSteps {
            let s = PipelineStep(name: step.name, prompt: step.prompt, sortOrder: step.sortOrder)
            modelContext.insert(s)
            s.pipeline = copy
            copy.steps = (copy.steps ?? []) + [s]
        }
        try? modelContext.save()
        selectedID = copy.id
    }
}

#Preview {
    let c = makePreviewContainer()
    return SettingsView()
        .modelContainer(c)
        .frame(width: 740, height: 520)
}
