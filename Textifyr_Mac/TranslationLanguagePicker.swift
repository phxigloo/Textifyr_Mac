import SwiftUI

// MARK: - Language model

struct TranslationLanguage: Identifiable, Hashable {
    let id: String
    let name: String
    /// True = in Apple Intelligence's known supported language set.
    /// False = may require a language pack installed in System Settings → Language & Region.
    let isSupported: Bool

    var promptText: String {
        "Translate the following text to \(name). Return only the translated text, with no preamble or explanation."
    }
}

let translationLanguages: [TranslationLanguage] = [
    // Apple Intelligence writing-tools languages (iOS 18 / macOS 15 rollout)
    .init(id: "zh-Hans", name: "Chinese (Simplified)", isSupported: true),
    .init(id: "fr",      name: "French",               isSupported: true),
    .init(id: "de",      name: "German",               isSupported: true),
    .init(id: "it",      name: "Italian",              isSupported: true),
    .init(id: "ja",      name: "Japanese",             isSupported: true),
    .init(id: "ko",      name: "Korean",               isSupported: true),
    .init(id: "pt-BR",   name: "Portuguese (Brazil)",  isSupported: true),
    .init(id: "es",      name: "Spanish",              isSupported: true),
    .init(id: "vi",      name: "Vietnamese",           isSupported: true),
    // Additional languages — results depend on installed language packs
    .init(id: "ar",      name: "Arabic",               isSupported: false),
    .init(id: "nl",      name: "Dutch",                isSupported: false),
    .init(id: "hi",      name: "Hindi",                isSupported: false),
    .init(id: "pl",      name: "Polish",               isSupported: false),
    .init(id: "ru",      name: "Russian",              isSupported: false),
    .init(id: "tr",      name: "Turkish",              isSupported: false),
]

// MARK: - Reusable button + popover

struct TranslateButton: View {
    var font: Font = .caption
    var helpText: String = "Translate text to another language"
    let onSelect: (TranslationLanguage) -> Void
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Label("Translate…", systemImage: "globe")
                .font(font)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(helpText)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            TranslationLanguagePopover { lang in
                showPopover = false
                onSelect(lang)
            }
        }
    }
}

// MARK: - Popover contents

struct TranslationLanguagePopover: View {
    let onSelect: (TranslationLanguage) -> Void

    private var supported: [TranslationLanguage] { translationLanguages.filter { $0.isSupported } }
    private var other: [TranslationLanguage]     { translationLanguages.filter { !$0.isSupported } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Translate To")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Supported")
                    ForEach(supported) { lang in
                        LanguageRow(language: lang, onSelect: { onSelect(lang) })
                    }
                    sectionHeader("May Require Setup")
                    ForEach(other) { lang in
                        LanguageRow(language: lang, onSelect: { onSelect(lang) })
                    }
                }
            }
            .frame(height: 260)

            Divider()

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                Text("If a language isn't available, results may be an error or the original text. Install language packs in **System Settings → General → Language & Region**.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 270)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

// MARK: - Single language row

private struct LanguageRow: View {
    let language: TranslationLanguage
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Text(language.name)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer()
                if !language.isSupported {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(language.isSupported ? "" : "May require a language pack installation")
    }
}
