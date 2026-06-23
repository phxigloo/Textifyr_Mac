import SwiftUI
import SwiftData
import AppKit
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

/// Create/edit a `WorkflowPreset`. `preset == nil` → new.
struct WorkflowSetupSheet: View {
    let preset: WorkflowPreset?
    /// True when shown as the detail pane of the Workflows workspace (fills the pane,
    /// no fixed frame, no Cancel; Save persists without dismissing).
    var isEmbedded: Bool = false
    /// Called after a save when embedded, so the workspace can keep selection in sync.
    var onSaved: (WorkflowPreset) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FormattingPipeline.name) private var pipelines: [FormattingPipeline]

    @State private var name = ""
    @State private var usesFileInput = true
    @State private var inputMethod: CaptureMethod = .microphone
    @State private var afterCaptureID: UUID?
    @State private var beforeCombiningID: UUID?
    @State private var finalDocumentID: UUID?
    @State private var reviewStage: WorkflowReviewStage = .never
    @State private var exportFormat: ExportFormat?
    @State private var exportBookmark: Data?
    @State private var exportFolderName = ""
    @State private var didLoad = false

    private let liveMethods: [CaptureMethod] = [.microphone, .screenCapture, .webURL, .camera, .appleIntelligence]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(preset == nil ? "New Workflow" : "Edit Workflow").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()

            Form {
                Section("Name") {
                    // Use `prompt:` (not the title) so the hint is in-field placeholder
                    // text that clears as you type — not a permanent left-side label.
                    TextField("Name", text: $name, prompt: Text("e.g. Weekly Meeting Notes"))
                        .labelsHidden()
                }

                Section("Input") {
                    Picker("Source", selection: $usesFileInput) {
                        Text("Use file(s)").tag(true)
                        Text("Live capture").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if usesFileInput {
                        Text("One or more files — each becomes a source (audio · video · PDF · image · text · RTF · CSV).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Method", selection: $inputMethod) {
                            ForEach(liveMethods, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                }

                Section("Pipelines") {
                    pipelinePicker("After Capture (each source)", scope: .postCapture, selection: $afterCaptureID)
                    pipelinePicker("Before Combining (each source)", scope: .source, selection: $beforeCombiningID)
                    pipelinePicker("Final Document (combined)", scope: .output, selection: $finalDocumentID)
                }

                Section("Pause for review") {
                    Picker("Stop to review/edit", selection: $reviewStage) {
                        ForEach(WorkflowReviewStage.allCases, id: \.self) { stage in
                            Text(stage.label).tag(stage)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    if reviewStage != .never {
                        Text("At each stop you can edit each source's text — with Find & Replace — before the workflow continues.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Export") {
                    Picker("Format", selection: $exportFormat) {
                        Text("Don't export").tag(ExportFormat?.none)
                        ForEach(ExportFormat.allCases, id: \.self) { f in
                            Text(f.rawValue.uppercased()).tag(ExportFormat?.some(f))
                        }
                    }
                    if exportFormat != nil {
                        HStack {
                            Text(exportBookmark == nil ? "Ask each time (Reveal in Finder)" : "Save to: \(exportFolderName)")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if exportBookmark != nil {
                                Button("Clear") { exportBookmark = nil; exportFolderName = "" }
                                    .buttonStyle(.borderless).controlSize(.small)
                            }
                            Button("Choose Folder…") { chooseFolder() }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(isEmbedded ? .hidden : .automatic)

            Divider()
            HStack {
                if !isEmbedded {
                    Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .modifier(SetupFrame(isEmbedded: isEmbedded))
        .background {
            if isEmbedded { VisualEffectBackground() }
        }
        .onAppear(perform: load)
    }

    // MARK: - Pipeline picker

    @ViewBuilder
    private func pipelinePicker(_ title: String, scope: PipelineScope, selection: Binding<UUID?>) -> some View {
        let options = pipelines.filter { $0.scope == scope && !$0.isHidden }
        Picker(title, selection: selection) {
            Text("None").tag(UUID?.none)
            ForEach(options) { p in
                Text(p.name).tag(UUID?.some(p.id))
            }
        }
    }

    // MARK: - Load / save

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let preset else { return }
        name = preset.name
        usesFileInput = preset.usesFileInput
        inputMethod = liveMethods.contains(preset.inputMethod) ? preset.inputMethod : .microphone
        afterCaptureID = preset.postCapturePipelineID
        beforeCombiningID = preset.sourcePipelineID
        finalDocumentID = preset.outputPipelineID
        reviewStage = preset.reviewStage
        exportFormat = preset.exportFormatRaw.flatMap(ExportFormat.init(rawValue:))
        exportBookmark = preset.exportDestinationBookmark
        exportFolderName = resolveFolderName(preset.exportDestinationBookmark)
    }

    private func save() {
        let wf = preset ?? WorkflowPreset(name: name)
        if preset == nil {
            wf.sortOrder = ((try? modelContext.fetch(FetchDescriptor<WorkflowPreset>()))?.count) ?? 0
            modelContext.insert(wf)
        }
        wf.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        wf.usesFileInput = usesFileInput
        wf.inputMethodRaw = inputMethod.rawValue
        wf.postCapturePipelineID = afterCaptureID
        wf.sourcePipelineID = beforeCombiningID
        wf.outputPipelineID = finalDocumentID
        wf.reviewStage = reviewStage
        wf.exportFormatRaw = exportFormat?.rawValue
        wf.exportDestinationBookmark = exportBookmark
        try? modelContext.save()
        if isEmbedded {
            onSaved(wf)
        } else {
            dismiss()
        }
    }

    // MARK: - Folder bookmark

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to save exports (e.g. Desktop)."
        // Open at the Desktop so granting Desktop access is a single click.
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            exportBookmark = data
            exportFolderName = url.lastPathComponent
        }
    }

    private func resolveFolderName(_ bookmark: Data?) -> String {
        guard let bookmark else { return "" }
        var stale = false
        let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        return url?.lastPathComponent ?? ""
    }
}

/// Fixed sheet size when modal; fills the pane when embedded as the Workflows detail.
private struct SetupFrame: ViewModifier {
    let isEmbedded: Bool
    func body(content: Content) -> some View {
        if isEmbedded {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.frame(width: 520, height: 560)
        }
    }
}
