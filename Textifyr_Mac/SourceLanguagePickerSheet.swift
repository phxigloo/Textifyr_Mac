import SwiftUI
import TextifyrServices

/// Asks which language the incoming text is in — our own picker, shown only when
/// `SourceLanguageResolver` has nothing defensible to offer (26.2).
///
/// The point is that this replaces Apple's bare "The language could not automatically be detected"
/// sheet, which appeared unexplained, mid-download, with no context about which instruction had
/// asked or why. Here the question is asked in place, with the recognizer's ranked guesses on top.
struct SourceLanguagePickerSheet: View {
    /// Ranked guesses from the recognizer, best first. May be empty.
    let candidates: [LanguageHypothesis]
    /// The language being translated *to*, excluded from the list — it can't also be the source.
    let targetCode: String
    let onPick: (String) -> Void
    let onCancel: () -> Void

    @ObservedObject private var catalog = TranslationCatalog.shared
    @State private var selection = ""

    /// Everything translatable except the target itself.
    private var allChoices: [TranslationCatalog.Language] {
        catalog.languages.filter { !catalog.isSameLanguage($0.id, targetCode) }
    }

    /// Recognizer guesses that are actually translatable, mapped onto catalog entries.
    private var suggested: [TranslationCatalog.Language] {
        candidates.compactMap { hypothesis in
            guard !catalog.isSameLanguage(hypothesis.code, targetCode) else { return nil }
            return catalog.language(for: hypothesis.code)
        }
    }

    private var others: [TranslationCatalog.Language] {
        let suggestedIDs = Set(suggested.map(\.id))
        return allChoices.filter { !suggestedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Which language is this text in?")
                    .font(.headline)
                Text("Textifyr couldn't tell automatically, and it needs to know before translating to \(catalog.label(for: targetCode)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            List(selection: $selection) {
                if !suggested.isEmpty {
                    Section("Likely") {
                        ForEach(suggested) { language in
                            row(language, confidence: confidence(for: language))
                        }
                    }
                }
                Section(suggested.isEmpty ? "Languages" : "All Languages") {
                    ForEach(others) { language in
                        row(language, confidence: nil)
                    }
                }
            }
            .listStyle(.inset)
            .frame(height: 300)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Use This Language") { onPick(selection) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 420)
        .task {
            await catalog.load()
            if selection.isEmpty { selection = suggested.first?.id ?? "" }
        }
    }

    private func row(_ language: TranslationCatalog.Language, confidence: Double?) -> some View {
        HStack {
            Text(language.name)
            Spacer()
            if let confidence {
                Text("\(Int((confidence * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("How confident the on-device recognizer is")
            }
        }
        .tag(language.id)
    }

    private func confidence(for language: TranslationCatalog.Language) -> Double? {
        candidates.first { catalog.isSameLanguage($0.code, language.id) }?.confidence
    }
}
