import SwiftUI
import SwiftData
import AppKit
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

/// Desktop-sampling translucency (behind-window blending) — the "glass" used by the
/// Documents detail. Apply as a `.background(...)` behind non-opaque detail content so
/// every mode's detail pane matches Documents.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
    }
}

// MARK: - Shared tool chrome (the Prompt Builder style, applied across all tools)

/// Opaque, rounded-inset card for a master / sub-master list — reads as a solid panel
/// floating on the translucent detail.
struct MasterListCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .padding(8)
    }
}

/// Section titlebar used atop every tool column (bold title on a `.bar` strip + divider).
struct ToolColumnHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 12)
            .background(.bar)
            Divider()
        }
    }
}

struct ContentView: View {
    @AppStorage(AppConstants.hasAcceptedTermsKey) private var hasAcceptedTerms = false
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if hasAcceptedTerms {
                MainNavigationView()
            } else {
                DisclaimerView()
            }
        }
        // Deep links arrive via the AppDelegate's Apple Event handler (not
        // onOpenURL) so SwiftUI doesn't open a duplicate window for them.
        .onReceive(NotificationCenter.default.publisher(for: .incomingDeepLink)) { note in
            if let url = note.object as? URL {
                appState.handleDeepLink(url)
                Task { await processShareQueueIfNeeded() }
            }
        }
        .task {
            // Process any items the Share Extension queued while the app was closed.
            await processShareQueueIfNeeded()
        }
        .onChange(of: appState.pendingShareQueueReady) { _, ready in
            if ready {
                appState.pendingShareQueueReady = false
                Task { await processShareQueueIfNeeded() }
            }
        }
        // Belt-and-suspenders: the Share Extension activates this app, so also
        // drain the queue whenever the app becomes active.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await processShareQueueIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .filesDropped)) { note in
            if let urls = note.object as? [URL] {
                FileDropImporter.handleDrop(urls: urls, into: nil, context: modelContext, appState: appState)
            }
        }
        .confirmationDialog(
            imageDropTitle,
            isPresented: Binding(
                // The buttons below are the only resolvers; the setter stays a no-op
                // so dismissing one prompt doesn't accidentally cancel the next queued batch.
                get: { appState.imageDropPrompt != nil },
                set: { _ in }
            ),
            titleVisibility: .visible
        ) {
            Button("Extract Text (OCR)") { DropImportCoordinator.shared.resolveImageChoice(.ocr) }
            Button("Embed Picture")      { DropImportCoordinator.shared.resolveImageChoice(.embed) }
            Button("Cancel", role: .cancel) { DropImportCoordinator.shared.resolveImageChoice(nil) }
        }
        .confirmationDialog(
            "Add \(appState.largeBatchPrompt?.fileCount ?? 0) files?",
            isPresented: Binding(
                get: { appState.largeBatchPrompt != nil },
                set: { _ in }
            ),
            titleVisibility: .visible,
            presenting: appState.largeBatchPrompt
        ) { prompt in
            Button("Add \(prompt.fileCount) Files") { DropImportCoordinator.shared.resolveLargeBatch(proceed: true, suppress: false) }
            Button("Don't Warn Me Again") { DropImportCoordinator.shared.resolveLargeBatch(proceed: true, suppress: true) }
            Button("Cancel", role: .cancel) { DropImportCoordinator.shared.resolveLargeBatch(proceed: false, suppress: false) }
        } message: { prompt in
            Text("You dropped \(prompt.fileCount) files. Each is extracted/transcribed and added as a source — that can take a while and use significant on-device processing.")
        }
    }

    private var imageDropTitle: String {
        let n = appState.imageDropPrompt?.imageCount ?? 0
        return n <= 1 ? "How should this image be added?" : "How should these \(n) images be added?"
    }

    private func processShareQueueIfNeeded() async {
        guard ShareExtensionQueue.checkHasItems() else { return }
        do {
            let items = try ShareExtensionQueue.dequeueAll()
            // Route through the coordinator so audio/video items open their wizard
            // one at a time instead of clobbering each other.
            DropImportCoordinator.shared.enqueueItems(
                items, groupKey: nil, context: modelContext, appState: appState)
        } catch {
            appState.showError("Could not read shared items: \(error.localizedDescription)")
        }
    }
}

// MARK: - Main navigation (Phase 22 single-window navigator)

private struct MainNavigationView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            ModeSelectorBar(mode: $appState.workspaceMode)
            Divider()
            Group {
                switch appState.workspaceMode {
                case .documents:     DocumentsWorkspace()
                case .actions:       ActionsWorkspace()
                case .promptBuilder: PromptBuilderView(isEmbedded: true)
                case .workflows:     WorkflowsWorkspace()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .collapseWindowToolbar()
        .alert("Error", isPresented: Binding(
            get: { appState.alertMessage != nil },
            set: { if !$0 { appState.clearAlert() } }
        )) {
            Button("OK") { appState.clearAlert() }
        } message: {
            Text(appState.alertMessage ?? "")
        }
        .workflowLaunchHost()
        // Menu commands / legacy notifications now switch workspace modes rather than
        // opening separate windows or app-level sheets (Phase 22).
        .onReceive(NotificationCenter.default.publisher(for: .openPipelineEditorSheet)) { _ in
            appState.workspaceMode = .actions
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPromptBuilderSheet)) { _ in
            appState.workspaceMode = .promptBuilder
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWorkflowManager)) { _ in
            appState.workspaceMode = .workflows
        }
    }
}

// MARK: - Mode selector bar (Xcode navigator-selector, horizontal, top)

private struct ModeSelectorBar: View {
    @Binding var mode: AppState.WorkspaceMode

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppState.WorkspaceMode.allCases, id: \.self) { m in
                Button { mode = m } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m.systemImage)
                            .font(.system(size: 12))
                        Text(m.title)
                            .font(.system(size: 12, weight: mode == m ? .semibold : .regular))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(mode == m ? Color.accentColor : Color.secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(mode == m ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(m.title)
            }
            Spacer()
            // Run Workflow lives here (global) — workflows are independent of the
            // current document, so this no longer sits in the Documents sidebar footer.
            WorkflowRunMenu()
        }
        // Left inset clears the hidden-title-bar traffic lights.
        .padding(.leading, 82)
        .padding(.trailing, 10)
        .frame(height: 38)
        .background(.bar)
    }
}

// MARK: - Run Workflow pulldown (global, in the mode bar)

/// "Run Workflow ▾" — a top-level action available from any workspace mode.
private struct WorkflowRunMenu: View {
    @EnvironmentObject private var appState: AppState
    @Query(sort: \WorkflowPreset.sortOrder) private var workflows: [WorkflowPreset]

    var body: some View {
        Menu {
            if workflows.isEmpty {
                Text("No workflows yet")
            } else {
                ForEach(workflows) { wf in
                    Button(wf.name.isEmpty ? "Untitled Workflow" : wf.name) {
                        appState.workflowToLaunch = wf
                    }
                }
            }
            Divider()
            Button("Manage Workflows…") { appState.workspaceMode = .workflows }
        } label: {
            Label("Run Workflow", systemImage: "wand.and.rays")
                .labelStyle(.titleAndIcon)
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Run a saved workflow")
    }
}

// MARK: - Documents workspace (the original main split view)

private struct DocumentsWorkspace: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @State private var sidebarVisible = true

    var body: some View {
        // Plain HStack of columns (not NavigationSplitView) so the column titlebars are
        // flush/flat like the Prompt Builder — macOS's split-view sidebar otherwise adds
        // its own inset rounded chrome + top displacement.
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView()
                    .frame(width: 260)
                Divider()
            }

            Group {
                if let doc = appState.selectedDocument {
                    DocumentEditorView(document: doc, context: modelContext)
                        .id(doc.id)
                } else {
                    EmptyStateView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VisualEffectBackground())
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            withAnimation { sidebarVisible.toggle() }
        }
    }
}

// MARK: - Actions workspace (the former Action Editor window, now a mode)

private struct ActionsWorkspace: View {
    var body: some View {
        // The Action Editor's three-column layout. Per-step "Improve" still opens the
        // Prompt Builder contextually (with a seed) via PipelineStepRow's own sheet;
        // the standalone Prompt Builder is the separate `.promptBuilder` mode.
        PipelineEditorWindowView()
    }
}

// MARK: - Workflows workspace (list + embedded editor — no popup)

private struct WorkflowsWorkspace: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkflowPreset.sortOrder) private var workflows: [WorkflowPreset]
    @State private var selectedID: UUID?

    private var selected: WorkflowPreset? { workflows.first { $0.id == selectedID } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ToolColumnHeader("Workflows")

                List(selection: $selectedID) {
                    ForEach(workflows) { wf in
                        WorkflowListRow(workflow: wf).tag(wf.id)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { delete(wf) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button("Delete", role: .destructive) { delete(wf) }
                            }
                    }
                    .onMove(perform: move)
                }
                .listStyle(.inset)
                .modifier(MasterListCard())

                Divider()

                HStack(spacing: 12) {
                    Button { addWorkflow() } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(.borderless).help("New Workflow")

                    Button { if let wf = selected { delete(wf) } } label: {
                        Image(systemName: "minus").font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(.borderless).disabled(selected == nil).help("Delete selected workflow")

                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(.bar)
            }
            .frame(width: 260)

            Divider()

            Group {
                if let wf = selected {
                    WorkflowSetupSheet(preset: wf, isEmbedded: true, onSaved: { selectedID = $0.id })
                        .id(wf.id)
                } else {
                    ContentUnavailableView(
                        "No Workflow Selected",
                        systemImage: "arrow.triangle.branch",
                        description: Text("Choose a workflow from the list, or tap + to create one.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VisualEffectBackground())
    }

    private func addWorkflow() {
        let wf = WorkflowPreset(name: "New Workflow")
        wf.sortOrder = workflows.count
        modelContext.insert(wf)
        try? modelContext.save()
        selectedID = wf.id
    }

    private func delete(_ wf: WorkflowPreset) {
        if selectedID == wf.id { selectedID = nil }
        modelContext.delete(wf)
        try? modelContext.save()
    }

    private func move(from: IndexSet, to: Int) {
        var arr = workflows
        arr.move(fromOffsets: from, toOffset: to)
        for (i, wf) in arr.enumerated() { wf.sortOrder = i }
        try? modelContext.save()
    }
}

private struct WorkflowListRow: View {
    let workflow: WorkflowPreset

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: workflow.usesFileInput ? "doc.on.doc" : workflow.inputMethod.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.name.isEmpty ? "Untitled Workflow" : workflow.name)
                    .font(.body)
                    .lineLimit(1)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        var parts = [workflow.usesFileInput ? "File(s)" : workflow.inputMethod.displayName]
        if workflow.reviewStage != .never { parts.append("review") }
        if let raw = workflow.exportFormatRaw { parts.append("→ \(raw.uppercased())") }
        return parts.joined(separator: " · ")
    }
}

#Preview {
    let c = makePreviewContainer()
    let appState = previewAppState(selectedIn: c)
    return ContentView()
        .modelContainer(c)
        .environmentObject(appState)
        .frame(width: 1100, height: 700)
}
