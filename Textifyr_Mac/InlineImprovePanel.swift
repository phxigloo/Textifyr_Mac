import SwiftUI
import SwiftData
import TextifyrModels
import TextifyrServices
import TextifyrViewModels

// SavePromptToLibrarySheet lives in PromptBuilderView.swift (same module).

/// Self-contained prompt test/improve panel shown inside `ScopedPipelineEditorSheet` (Spec 2).
/// Runs and improves a single step's prompt **against the captured transcript** without ever
/// navigating to the main-window Prompt Builder — which would unmount the wizard the sheet is
/// presented over. Slides in from the trailing edge, matching the Actions Inspector pattern.
struct InlineImprovePanel: View {
    @ObservedObject var viewModel: PipelineEditorViewModel
    let stepIndex: Int
    let sampleText: String
    let onClose: () -> Void

    @Query private var savedPrompts: [SavedPrompt]

    @State private var promptText = ""
    @State private var feedback = ""
    @State private var runOutput = ""
    @State private var didRun = false
    @State private var isRunning = false
    @State private var errorText: String?
    @State private var runTask: Task<Void, Never>?
    @State private var showSaveToLibrary = false
    @State private var showPromptLibrary = false

    private var step: PipelineStep? {
        viewModel.steps.indices.contains(stepIndex) ? viewModel.steps[stepIndex] : nil
    }

    private var isImprovingThisStep: Bool {
        viewModel.isImprovingPrompt && viewModel.improvingStepID == step?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let step {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        promptSection(step)
                        testSection
                        Divider()
                        improveSection(step)
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView("Step removed", systemImage: "wand.and.stars")
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .onAppear { promptText = step?.prompt ?? "" }
        .onChange(of: stepIndex) { _, _ in resetForStep() }
        .onDisappear { runTask?.cancel() }
        .sheet(isPresented: $showSaveToLibrary) {
            SavePromptToLibrarySheet(
                promptText: promptText,
                initialScope: viewModel.pipeline.scope,
                nextSortOrder: savedPrompts.count
            )
        }
        .sheet(isPresented: $showPromptLibrary) {
            // Browse/load/rename/duplicate/delete saved prompts. Loading one replaces this step's
            // prompt; delete/manage close the loop so a prompt saved here can also be removed here.
            LoadExistingPromptSheet(scopeFilter: viewModel.pipeline.scope) { loaded in
                promptText = loaded.text
                if let step { viewModel.updateStep(step, name: step.name, prompt: loaded.text) }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").foregroundStyle(.tint)
            Text("Test & Improve").font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Prompt

    private func promptSection(_ step: PipelineStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                label("PROMPT")
                Spacer()
                Menu {
                    Button("Save to Library…") { showSaveToLibrary = true }
                        .disabled(promptText.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Browse & Manage…") { showPromptLibrary = true }
                } label: {
                    Label("Library", systemImage: "books.vertical").font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Save this prompt to the reusable library, or browse/manage saved prompts")
            }
            TextEditor(text: $promptText)
                .font(.callout)
                .frame(minHeight: 96, maxHeight: 180)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
                .onChange(of: promptText) { _, v in viewModel.updateStep(step, name: step.name, prompt: v) }
        }
    }

    // MARK: - Test against captured text

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                label("TEST ON CAPTURED TEXT")
                Spacer()
                if isRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { runTask?.cancel(); runTask = nil; isRunning = false }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button("Run") { run() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(sampleText.isEmpty || promptText.isEmpty)
                }
            }

            if sampleText.isEmpty {
                Text("No captured text to test against yet.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            if didRun {
                ScrollView {
                    Text(runOutput.isEmpty ? "(empty result)" : runOutput)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 200)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
            }
        }
    }

    // MARK: - Improve with AI

    private func improveSection(_ step: PipelineStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label("IMPROVE WITH AI")
            TextField("What should change? (e.g. keep bullet points)", text: $feedback, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .lineLimit(2...4)
                .disabled(isImprovingThisStep)
            HStack {
                Text("Rewrites the prompt above — Run again to compare.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if isImprovingThisStep {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Improve") {
                        Task {
                            await viewModel.improvePrompt(step: step, feedback: feedback)
                            promptText = step.prompt
                            feedback = ""
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(feedback.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: - Helpers

    private func label(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.tertiary).textCase(.uppercase)
    }

    private func resetForStep() {
        runTask?.cancel(); runTask = nil
        promptText = step?.prompt ?? ""
        feedback = ""; runOutput = ""; didRun = false; errorText = nil; isRunning = false
    }

    /// Runs the action from its first step up to and including this one over the captured text,
    /// so the result reflects this step's effect in context (not the step in isolation).
    private func run() {
        errorText = nil
        isRunning = true
        let pipeline = viewModel.pipeline
        let text = sampleText
        let upTo = stepIndex + 1
        runTask = Task { @MainActor in
            do {
                let records = try await DocumentFormattingService().runRange(
                    pipeline: pipeline, sourceText: text, range: 0..<upTo)
                runOutput = records.last?.output ?? ""
                didRun = true
            } catch is CancellationError {
                // user cancelled — leave prior result in place
            } catch {
                errorText = error.localizedDescription
            }
            isRunning = false
            runTask = nil
        }
    }
}
