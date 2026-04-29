import SwiftUI
import SwiftData
import AppKit
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

// MARK: - Root

struct SettingsView: View {
    private enum Tab: Hashable {
        case general, textProcessing, stages, windows
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

            WindowsTab()
                .tabItem { Label("Windows",         systemImage: "macwindow") }
                .tag(Tab.windows)
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

// MARK: - 10.2 General

private struct GeneralTab: View {
    @AppStorage(AppConstants.hasAcceptedTermsKey)        private var hasAcceptedTerms        = true
    @AppStorage(AppConstants.hasShownAIPrivacyWarningKey) private var hasShownAIPrivacyWarning = false
    @AppStorage(AppConstants.localProcessingOnlyKey)     private var localProcessingOnly      = false

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

// MARK: - 10.3 Text Processing

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
            // Auto-cleanup toggle
            Section("Auto-Cleanup") {
                Toggle("Apply post-processing on import", isOn: $postProcessingEnabled)
                Text("Removes filler words, normalises punctuation, and applies find/replace rules when text is captured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Filler words
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

            // Find & replace rules
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
                            .foregroundStyle(.primary)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Group {
                            if rule.replace.isEmpty {
                                Text("(remove)")
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(rule.replace)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            cleanupRules.removeAll { $0.id == rule.id }
                            saveCleanupRules()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.body)
                }

                HStack(spacing: 8) {
                    TextField("Find…", text: $newFind)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Replace with…", text: $newReplace)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") { addCleanupRule() }
                        .disabled(newFind.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            // Default pipeline
            Section("Default Pipeline") {
                Picker("New document pipeline", selection: $defaultPipelineID) {
                    Text("None").tag("")
                    ForEach(pipelines) { pipeline in
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

    // MARK: - Filler words

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

    // MARK: - Cleanup rules

    private func addCleanupRule() {
        let find = newFind.trimmingCharacters(in: .whitespaces)
        guard !find.isEmpty else { return }
        cleanupRules.append(CleanupRule(find: find, replace: newReplace))
        newFind    = ""
        newReplace = ""
        saveCleanupRules()
    }

    private func saveCleanupRules() {
        let raw = cleanupRules.map { ["find": $0.find, "replace": $0.replace] }
        UserDefaults.standard.set(raw, forKey: AppConstants.cleanupRulesKey)
    }

    // MARK: - Load

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

// MARK: - 10.4 Stages

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
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
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
                Button {
                    showAddSheet = true
                } label: {
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
        self.stage   = stage
        self.context = context
        _name      = State(initialValue: stage?.name ?? "New Stage")
        _bgColor   = State(initialValue: stage?.color ?? .blue)
        _textColor = State(initialValue: stage?.textColor ?? .white)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(stage == nil ? "New Stage" : "Edit Stage")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
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
            stage.name         = trimmed
            stage.colorHex     = bgHex
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

// MARK: - 10.5 Windows

private struct WindowsTab: View {
    @AppStorage(AppConstants.maxDocumentWindowsKey) private var maxDocumentWindows = AppConstants.defaultMaxDocumentWindows
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
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

            Section("Pipeline Editor") {
                LabeledContent("Manage pipelines") {
                    Button("Open Pipeline Editor") {
                        openWindow(id: "pipeline-editor")
                    }
                    .buttonStyle(.bordered)
                }
                Text("Create, edit, and organise formatting pipelines. Also accessible via \u{2318}\u{21E7}P.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
