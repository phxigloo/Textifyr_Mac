import SwiftUI
import SwiftData
import AppKit
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

/// Drives one workflow run: creates the target document, runs the engine, shows
/// progress, and (in review mode) lets the user edit each source before the
/// Final Document stage. `onClose(openedDocument:)` — true means the manager
/// should close so the user sees the resulting document.
struct WorkflowRunnerView: View {
    let preset: WorkflowPreset
    let fileURLs: [URL]
    /// When set, run the chain on this existing document (live-capture resume) and
    /// skip the import step. Otherwise a new document is created from `fileURLs`.
    var existingDocument: TextifyrDocument? = nil
    let onClose: (_ openedDocument: Bool) -> Void

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = WorkflowPresetViewModel()
    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 540, height: 460)
        .onAppear(perform: startIfNeeded)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name.isEmpty ? "Workflow" : preset.name).font(.headline)
                Text(headline).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var icon: String {
        switch vm.stage {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .review: return "pause.circle.fill"
        default: return "gearshape.2.fill"
        }
    }

    private var headline: String {
        if vm.isPausedForReview { return "Paused for review" }
        switch vm.stage {
        case .done: return "Finished"
        case .failed: return "Stopped"
        default: return "Running…"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.isPausedForReview {
            reviewContent
        } else if vm.stage == .done {
            doneContent
        } else if vm.stage == .failed {
            failedContent
        } else {
            runningContent
        }
    }

    private var runningContent: some View {
        VStack(spacing: 16) {
            stageChecklist
            VStack(alignment: .leading, spacing: 6) {
                Text(vm.detail).font(.callout).foregroundStyle(.secondary)
                ProgressView(value: vm.progress).progressViewStyle(.linear)
                    .animation(.linear(duration: 0.25), value: vm.progress)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(20)
    }

    private var stageChecklist: some View {
        let stages: [(WorkflowPresetViewModel.Stage, String)] = [
            (.importing, "Import file(s)"),
            (.afterCapture, "After Capture"),
            (.beforeCombining, "Before Combining"),
            (.finalDocument, "Final Document"),
            (.exporting, "Export"),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(stages, id: \.0) { item in
                HStack(spacing: 8) {
                    Image(systemName: symbol(for: item.0))
                        .foregroundStyle(color(for: item.0)).frame(width: 18)
                    Text(item.1)
                        .foregroundStyle(item.0 == vm.stage ? .primary : .secondary)
                    Spacer()
                }
                .font(.callout)
            }
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(vm.detail.isEmpty ? "Review each source, then continue." : vm.detail)
                .font(.callout).foregroundStyle(.secondary)
            Text("Tip: use the magnifying-glass (or ⌘F) for Find & Replace.")
                .font(.caption).foregroundStyle(.tertiary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(sessions) { session in
                        ReviewSourceEditor(session: session)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(20)
    }

    private var doneContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text("Workflow complete").font(.headline)
            Text("\(vm.importedCount) source\(vm.importedCount == 1 ? "" : "s") added.")
                .font(.callout).foregroundStyle(.secondary)
            if let err = vm.errorMessage {
                Text(err).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private var failedContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
            Text("Workflow stopped").font(.headline)
            Text(vm.errorMessage ?? vm.detail).font(.callout)
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            if vm.isPausedForReview {
                Button("Stop") { vm.cancel(); openDocument() }.buttonStyle(.bordered)
                Spacer()
                Button("Continue to Final Document") { vm.continueRun() }
                    .buttonStyle(.borderedProminent)
            } else if vm.stage == .done {
                if let url = vm.exportedFileURL {
                    Button("Reveal Export") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.bordered)
                    Button("Save to Desktop…") { saveExportToDesktop() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button("Open Document") { openDocument() }.buttonStyle(.borderedProminent)
            } else if vm.stage == .failed {
                Spacer()
                Button("Close") { openDocument() }.buttonStyle(.borderedProminent)
            } else {
                Button("Stop") { vm.cancel() }.buttonStyle(.bordered)
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.bar)
    }

    // MARK: - Helpers

    private var sessions: [SourceSession] {
        (vm.activeDocument?.sourceSessions ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        if let existingDocument {
            // Live-capture resume: sources already captured; run the chain on them.
            vm.run(preset, in: existingDocument, fileURLs: [], context: modelContext)
        } else {
            let doc = TextifyrDocument(title: documentTitle())
            doc.sortOrder = ((try? modelContext.fetch(FetchDescriptor<TextifyrDocument>()))?.count) ?? 0
            modelContext.insert(doc)
            vm.run(preset, in: doc, fileURLs: fileURLs, context: modelContext)
        }
    }

    private func documentTitle() -> String {
        if let first = fileURLs.first {
            let base = first.deletingPathExtension().lastPathComponent
            return fileURLs.count > 1 ? "\(base) +\(fileURLs.count - 1)" : base
        }
        return preset.name.isEmpty ? "Workflow" : preset.name
    }

    private func openDocument() {
        if let doc = vm.activeDocument { appState.selectedDocument = doc }
        onClose(true)
    }

    /// Sandbox-safe one-click export to the Desktop: a save panel pre-pointed at the
    /// Desktop with a friendly filename. (Saving via the panel grants write access,
    /// so this works without the one-time folder grant in the workflow's settings.)
    private func saveExportToDesktop() {
        guard let src = vm.exportedFileURL else { return }
        let base = vm.activeDocument?.title.isEmpty == false ? vm.activeDocument!.title : "Export"
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = "\(safe).\(src.pathExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: src, to: dest)
    }

    private func symbol(for stage: WorkflowPresetViewModel.Stage) -> String {
        if isComplete(stage) { return "checkmark.circle.fill" }
        if stage == vm.stage { return "circle.dotted" }
        return "circle"
    }

    private func color(for stage: WorkflowPresetViewModel.Stage) -> Color {
        if isComplete(stage) { return .green }
        if stage == vm.stage { return .accentColor }
        return .secondary
    }

    /// A stage is "complete" if the run has moved past it.
    private func isComplete(_ stage: WorkflowPresetViewModel.Stage) -> Bool {
        order(vm.stage) > order(stage) || vm.stage == .done
    }

    private func order(_ stage: WorkflowPresetViewModel.Stage) -> Int {
        switch stage {
        case .idle: return 0
        case .importing: return 1
        case .afterCapture: return 2
        case .beforeCombining: return 3
        case .review: return 4
        case .finalDocument: return 5
        case .exporting: return 6
        case .done: return 7
        case .failed: return -1
        }
    }
}

// MARK: - Review source editor (with Find & Replace)

/// One source's text in a review checkpoint: an editable box with the standard
/// macOS find bar (⌘F, includes Replace / Replace All) for fixing recurring
/// strings — e.g. "Apple Bee" → "Applebee".
private struct ReviewSourceEditor: View {
    @Bindable var session: SourceSession
    @State private var showFind = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.captureMethod.displayName)
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button { showFind.toggle() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("Find & Replace (⌘F)")
            }
            TextEditor(text: $session.rawText)
                .font(.callout)
                .frame(minHeight: 80, maxHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .findNavigator(isPresented: $showFind)
        }
    }
}
