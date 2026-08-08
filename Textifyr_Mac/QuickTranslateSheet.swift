import SwiftUI
import TextifyrModels
import TextifyrServices

/// One-off translation of the text in front of you (26.7).
///
/// This is the *same* `.translate` instruction the pipeline runs — same `TranslateConfig`, same
/// editor, same engine — just not saved anywhere yet. The two toolbar buttons used to build an LLM
/// prompt instead, which meant two visually identical "Translate" affordances with different engines,
/// different language coverage, and different failure modes. Now there's one engine, and "Save as
/// Instruction…" turns a one-off into something reusable in an action or workflow.
struct QuickTranslateSheet: View {
    let sourceText: String
    let onTranslated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = TranslationCatalog.shared

    @State private var config = TranslateConfig()
    @State private var isRunning = false
    @State private var errorText: String?
    @State private var recoveryText: String?
    /// Shown only after the framework says it can't do this pair at all.
    @State private var offerAIFallback = false
    @State private var showSaveSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Translate").font(.headline)
                Text("\(sourceText.count.formatted()) characters · runs on this Mac, no AI")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                TranslateConfigEditor(config: $config, sampleText: sourceText)

                if let errorText {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if let recoveryText {
                            Text(recoveryText)
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if offerAIFallback {
                    // Deliberately a separate, labelled action rather than a silent fallback: Apple's
                    // framework covers 21 languages, Apple Intelligence will attempt more but less
                    // reliably, and the user should know which one produced their text.
                    Button { runWithAI() } label: {
                        Label("Translate with AI instead", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Uses Apple Intelligence rather than on-device translation. Wider language coverage, less predictable results.")
                }
            }
            .padding(20)

            Spacer(minLength: 0)

            Divider()

            HStack {
                Button("Save as Instruction…") { showSaveSheet = true }
                    .disabled(!config.hasTarget)
                    .help("Keep this as a reusable instruction you can add to an action or workflow")
                Spacer()
                if isRunning { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Translate") { run() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!config.hasTarget || isRunning || sourceText.isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 460, height: 340)
        .sheet(isPresented: $showSaveSheet) {
            SavePromptToLibrarySheet(
                promptText: "",
                nextSortOrder: 0,
                kind: .translate,
                translateConfigJSON: config.encodedString())
        }
    }

    private var effectiveTarget: String {
        config.effectiveTargetCode(systemCode: catalog.systemLanguageCode)
    }

    private func run() {
        guard config.hasTarget, !sourceText.isEmpty else { return }
        isRunning = true
        errorText = nil
        recoveryText = nil
        offerAIFallback = false

        Task { @MainActor in
            do {
                let result = try await TranslationCoordinator.shared.translate(
                    sourceText, sourceCode: config.sourceLanguageCode, targetCode: effectiveTarget)
                onTranslated(result)
                dismiss()
            } catch let failure as TranslationFailure {
                if !failure.isCancelled {
                    errorText = failure.errorDescription
                    recoveryText = failure.recoverySuggestion
                    offerAIFallback = failure.isUnsupportedPair
                }
            } catch {
                errorText = error.localizedDescription
            }
            isRunning = false
        }
    }

    /// The old LLM route, kept only as an explicit escape hatch for pairs the framework can't do.
    private func runWithAI() {
        isRunning = true
        errorText = nil
        let name = catalog.label(for: effectiveTarget)
        let prompt = "Translate the following text to \(name). "
            + "Return only the translated text, with no preamble or explanation."

        Task { @MainActor in
            do {
                let result = try await DocumentFormattingService()
                    .formatWithPrompt(sourceText: sourceText, systemPrompt: prompt)
                onTranslated(result)
                dismiss()
            } catch {
                errorText = error.localizedDescription
                recoveryText = nil
            }
            isRunning = false
        }
    }
}
