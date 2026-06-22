import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

// MARK: - Manager

/// Tools → Workflows… — a selectable, drag-to-reorder list with a +/- footer and a
/// Run button, matching the app's sidebar style. Management lives here (next to
/// Pipeline Editor / Prompt Builder), not in the document sidebar (HIG: sidebars
/// are for content, not actions). Running is delegated to the launch host.
struct WorkflowManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @Query(sort: \WorkflowPreset.sortOrder) private var workflows: [WorkflowPreset]

    @State private var selectedID: UUID?
    @State private var editing: WorkflowPreset?
    @State private var showEditor = false

    private var selected: WorkflowPreset? { workflows.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workflows").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()

            if workflows.isEmpty {
                emptyState
            } else {
                List(selection: $selectedID) {
                    ForEach(workflows) { wf in
                        WorkflowRow(workflow: wf)
                            .tag(wf.id)
                            .contextMenu {
                                Button("Run") { run(wf) }
                                Button("Edit") { edit(wf) }
                                Button("Duplicate") { duplicate(wf) }
                                Divider()
                                Button("Delete", role: .destructive) { delete(wf) }
                            }
                    }
                    .onMove(perform: move)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()
            footer
        }
        .frame(width: 580, height: 480)
        .sheet(isPresented: $showEditor) {
            WorkflowSetupSheet(preset: editing)
        }
    }

    // MARK: - Footer (+/- · Edit · Run)

    private var footer: some View {
        HStack(spacing: 12) {
            // Source-list add/remove controls live at the bottom-left (HIG).
            Button { newWorkflow() } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.borderless).help("New Workflow")

            Button { if let wf = selected { delete(wf) } } label: {
                Image(systemName: "minus").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.borderless).disabled(selected == nil).help("Delete selected workflow")

            Spacer()

            Button("Edit") { if let wf = selected { edit(wf) } }
                .disabled(selected == nil)
            Button { if let wf = selected { run(wf) } } label: {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent).disabled(selected == nil)

            // Dismiss lives in the bottom bar with the other controls (not the header).
            // It's "Done", not "Cancel": add/delete/reorder are committed live, so
            // there's nothing to cancel. Esc also closes.
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "wand.and.rays")
                .font(.system(size: 42)).foregroundStyle(.tertiary)
            Text("No Workflows Yet").font(.headline)
            Text("A workflow chains capture → AI clean-up → combine → final formatting → export into one action.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button { newWorkflow() } label: { Label("New Workflow", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Actions

    private func newWorkflow() { editing = nil; showEditor = true }
    private func edit(_ wf: WorkflowPreset) { editing = wf; showEditor = true }

    private func run(_ wf: WorkflowPreset) {
        dismiss()
        appState.workflowToLaunch = wf
    }

    private func move(from: IndexSet, to: Int) {
        var arr = workflows
        arr.move(fromOffsets: from, toOffset: to)
        for (i, wf) in arr.enumerated() { wf.sortOrder = i }
        try? modelContext.save()
    }

    private func duplicate(_ wf: WorkflowPreset) {
        let copy = WorkflowPreset(name: wf.name + " copy")
        copy.usesFileInput = wf.usesFileInput
        copy.inputMethodRaw = wf.inputMethodRaw
        copy.reviewStageRaw = wf.reviewStageRaw
        copy.postCapturePipelineID = wf.postCapturePipelineID
        copy.sourcePipelineID = wf.sourcePipelineID
        copy.outputPipelineID = wf.outputPipelineID
        copy.exportFormatRaw = wf.exportFormatRaw
        copy.exportDestinationBookmark = wf.exportDestinationBookmark
        copy.sortOrder = workflows.count
        modelContext.insert(copy)
        try? modelContext.save()
    }

    private func delete(_ wf: WorkflowPreset) {
        if selectedID == wf.id { selectedID = nil }
        modelContext.delete(wf)
        try? modelContext.save()
    }
}

// MARK: - Row

private struct WorkflowRow: View {
    let workflow: WorkflowPreset

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: workflow.usesFileInput ? "doc.on.doc" : workflow.inputMethod.systemImage)
                .font(.system(size: 18)).foregroundStyle(.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.name.isEmpty ? "Untitled Workflow" : workflow.name)
                    .font(.body.weight(.medium))
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var summary: String {
        var parts: [String] = [workflow.usesFileInput ? "File(s)" : workflow.inputMethod.displayName]
        if workflow.reviewStage != .never { parts.append("review") }
        if let raw = workflow.exportFormatRaw { parts.append("→ \(raw.uppercased())") }
        return parts.joined(separator: " · ")
    }
}
