import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

/// A new (file-input) workflow run awaiting presentation.
struct WorkflowRunRequest: Identifiable {
    let id = UUID()
    let preset: WorkflowPreset
    let fileURLs: [URL]
}

/// Centralises *launching* a workflow run so every surface — the sidebar pulldown,
/// the Tools-menu manager, and live-capture resume — funnels through one place.
/// Attach once near the main window via `.workflowLaunchHost()`.
struct WorkflowLaunchModifier: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext

    @State private var runRequest: WorkflowRunRequest?
    @State private var pendingLargeBatch: WorkflowRunRequest?

    private static let importTypes: [UTType] =
        [.audio, .movie, .pdf, .image, .plainText, .rtf, .commaSeparatedText, .tabSeparatedText]
    private static let largeBatchThreshold = 15
    private static let suppressLargeBatchKey = "suppressLargeBatchWarning"

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.workflowToLaunch?.id) { _, _ in handleLaunch() }
            .confirmationDialog(
                "Process \(pendingLargeBatch?.fileURLs.count ?? 0) files?",
                isPresented: Binding(get: { pendingLargeBatch != nil }, set: { _ in }),
                titleVisibility: .visible,
                presenting: pendingLargeBatch
            ) { req in
                Button("Process \(req.fileURLs.count) Files") { runRequest = req; pendingLargeBatch = nil }
                Button("Don't Warn Me Again") {
                    UserDefaults.standard.set(true, forKey: Self.suppressLargeBatchKey)
                    runRequest = req; pendingLargeBatch = nil
                }
                Button("Cancel", role: .cancel) { pendingLargeBatch = nil }
            } message: { req in
                Text("This workflow will transcribe/extract and AI-process \(req.fileURLs.count) files. That can take a while and use significant on-device processing.")
            }
            .sheet(item: $runRequest) { req in
                WorkflowRunnerView(preset: req.preset, fileURLs: req.fileURLs) { _ in
                    runRequest = nil
                }
                .environmentObject(appState)
            }
            .sheet(item: $appState.liveWorkflowResume) { req in
                LiveWorkflowResumeView(request: req)
                    .environmentObject(appState)
            }
            .sheet(item: $appState.rerunFlaggedRequest) { req in
                RerunFlaggedView(request: req)
                    .environmentObject(appState)
            }
    }

    private func handleLaunch() {
        guard let wf = appState.workflowToLaunch else { return }
        appState.workflowToLaunch = nil
        if wf.usesFileInput {
            chooseFiles(for: wf)
        } else {
            // Live capture: create the document, select it, remember the workflow,
            // and open the capture wizard. SourcesTabView resumes the chain when the
            // capture completes (see appState.liveWorkflowPending).
            let doc = TextifyrDocument(title: wf.name.isEmpty ? "Workflow" : wf.name)
            doc.sortOrder = ((try? modelContext.fetch(FetchDescriptor<TextifyrDocument>()))?.count) ?? 0
            modelContext.insert(doc)
            try? modelContext.save()
            appState.selectedDocument = doc
            appState.liveWorkflowPending = LiveWorkflowRequest(presetID: wf.id, documentID: doc.id)
            appState.pendingSourceMethod = wf.inputMethod
        }
    }

    /// Deliberately NSOpenPanel, not SwiftUI's `.fileImporter`. This modifier is attached at
    /// the ContentView root, and an ancestor `.fileImporter` silently suppresses every
    /// `.fileImporter` a descendant declares — which is every capture wizard's "Choose File…".
    /// Only one `.fileImporter` in an ancestor chain ever presents, so this one must not exist.
    private func chooseFiles(for preset: WorkflowPreset) {
        // Off the current update pass: runModal() spins its own loop.
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = Self.importTypes
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.message = "Choose files for “\(preset.name)”"

            guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
            let req = WorkflowRunRequest(preset: preset, fileURLs: panel.urls)
            if panel.urls.count >= Self.largeBatchThreshold,
               !UserDefaults.standard.bool(forKey: Self.suppressLargeBatchKey) {
                pendingLargeBatch = req
            } else {
                runRequest = req
            }
        }
    }
}

extension View {
    func workflowLaunchHost() -> some View { modifier(WorkflowLaunchModifier()) }
}

/// Resolves a live-capture resume request to its preset + document and runs the
/// post-capture chain on the already-captured sources.
private struct LiveWorkflowResumeView: View {
    let request: LiveWorkflowRequest
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let preset = resolvePreset(), let doc = resolveDocument() {
            WorkflowRunnerView(preset: preset, fileURLs: [], existingDocument: doc) { _ in
                appState.liveWorkflowResume = nil
            }
            .environmentObject(appState)
        } else {
            Color.clear.frame(width: 1, height: 1)
                .onAppear { appState.liveWorkflowResume = nil }
        }
    }

    private func resolvePreset() -> WorkflowPreset? {
        ((try? modelContext.fetch(FetchDescriptor<WorkflowPreset>())) ?? []).first { $0.id == request.presetID }
    }
    private func resolveDocument() -> TextifyrDocument? {
        ((try? modelContext.fetch(FetchDescriptor<TextifyrDocument>())) ?? []).first { $0.id == request.documentID }
    }
}

/// Resolves a "re-run flagged sources" request (21.5) to its preset + document and
/// runs the source chain on only the flagged sources, then re-finalizes + exports.
private struct RerunFlaggedView: View {
    let request: LiveWorkflowRequest
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let preset = resolvePreset(), let doc = resolveDocument() {
            WorkflowRunnerView(preset: preset, fileURLs: [], existingDocument: doc, rerunFlagged: true) { _ in
                appState.rerunFlaggedRequest = nil
            }
            .environmentObject(appState)
        } else {
            Color.clear.frame(width: 1, height: 1)
                .onAppear { appState.rerunFlaggedRequest = nil }
        }
    }

    private func resolvePreset() -> WorkflowPreset? {
        ((try? modelContext.fetch(FetchDescriptor<WorkflowPreset>())) ?? []).first { $0.id == request.presetID }
    }
    private func resolveDocument() -> TextifyrDocument? {
        ((try? modelContext.fetch(FetchDescriptor<TextifyrDocument>())) ?? []).first { $0.id == request.documentID }
    }
}
