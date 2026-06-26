import SwiftUI
import AppKit
import TextifyrModels

/// Read-only drill-down of a source's captured last-run trace (Phase 23.2).
///
/// Lists every step (grouped by stage) with its character delta and a failure marker;
/// selecting a step shows its *real* input and output (the faithful record from the run,
/// not a recompute). Pre-positions at the failed step when there is one — so a failure and
/// a "why is this output wrong?" inspection are the same surface. Shared component: hosted
/// in the source editor now, and (later) the capture wizard + run checkpoints.
struct RunTraceInspectorView: View {
    let trace: RunTrace
    /// Opens the selected step in the *right* editor for its kind (23.3): AI steps → Prompt
    /// Builder (seeded with this step's prompt + input); deterministic steps → Action editor.
    var onOpenStepEditor: ((StepTraceRecord) -> Void)? = nil
    /// Re-runs the action from this step forward on its captured input (23.7) — confirm a
    /// fix propagates to the action's output. Hidden for a failed step (its output is empty).
    var onRerunFromHere: ((StepTraceRecord) -> Void)? = nil

    @State private var selectedID: UUID?

    private var selected: StepTraceRecord? { trace.steps.first { $0.id == selectedID } }

    var body: some View {
        HStack(spacing: 0) {
            stepList
                .frame(width: 270)
                .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            detail
                .frame(maxWidth: .infinity)
        }
        .onAppear {
            if selectedID == nil {
                selectedID = (trace.steps.first { $0.failed } ?? trace.steps.last)?.id
            }
        }
    }

    // MARK: - Master: step list grouped by stage

    private var stepList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                ForEach(Array(trace.steps.enumerated()), id: \.element.id) { idx, step in
                    if idx == 0 || trace.steps[idx - 1].stage != step.stage {
                        Text(step.stage.uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, idx == 0 ? 12 : 16)
                            .padding(.bottom, 4)
                    }
                    stepRow(step)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stepRow(_ step: StepTraceRecord) -> some View {
        Button { selectedID = step.id } label: {
            HStack(spacing: 8) {
                Image(systemName: step.failed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(step.failed ? .orange : .green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.stepName).font(.callout).lineLimit(1)
                    Text("\(step.actionName) · \(charDelta(step))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selectedID == step.id ? Color.accentColor.opacity(0.18) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func charDelta(_ s: StepTraceRecord) -> String {
        s.failed
            ? "failed"
            : "\(s.input.count.formatted()) → \(s.output.count.formatted()) chars"
    }

    // MARK: - Detail: selected step's input / output

    @ViewBuilder
    private var detail: some View {
        if let step = selected {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.stepName).font(.headline)
                        Text("\(step.stage) · \(step.actionName)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !step.failed, let rerun = onRerunFromHere {
                        Button("Re-run from here") { rerun(step) }
                            .controlSize(.small)
                            .help("Re-run the action from this step forward on its captured input — confirm a fix reaches the output.")
                    }
                    if let open = onOpenStepEditor {
                        Button(step.editRoute == .promptBuilder ? "Improve in Prompt Builder" : "Open in Action Editor") {
                            open(step)
                        }
                        .controlSize(.small)
                        .help(step.editRoute == .promptBuilder
                              ? "Open the Prompt Builder with this AI step's prompt + input."
                              : "Open this step in the Action editor.")
                    }
                }
                .padding(16)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        textBlock("Input", step.input)
                        if step.failed {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Failed here", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption.bold()).foregroundStyle(.orange)
                                Text(step.failureReason.isEmpty ? "The step did not complete." : step.failureReason)
                                    .font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            textBlock("Output", step.output)
                        }
                    }
                    .padding(16)
                }
            }
        } else {
            Text("No run trace for this source.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func textBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.caption2).foregroundStyle(.tertiary)
                Text("\(title) · read-only").font(.caption.bold()).foregroundStyle(.secondary)
                Text("\(text.count.formatted()) chars")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                Spacer()
                Button { copyToPasteboard(text) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).controlSize(.small).help("Copy")
            }
            // Read-only transcript styling — a flat grouped panel + secondary text, so it
            // reads as a record rather than an editable field (23.3 / inspector feedback).
            Text(text.isEmpty ? "—" : text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
