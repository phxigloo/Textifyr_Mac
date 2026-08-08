import SwiftUI

/// Opens a one-off translation of the text in front of you (26.7).
///
/// Was a popover with its own language list that ran an **LLM prompt**; now it presents
/// `QuickTranslateSheet`, which runs the same `.translate` instruction the pipeline does. The
/// separate language list went with it — one list, in one editor, for one engine.
struct TranslateButton: View {
    var font: Font = .caption
    var helpText: String = "Translate this text to another language"
    var bordered: Bool = false
    /// Read when the sheet opens, so the caller can hand over whatever is current.
    let sourceText: () -> String
    /// Receives the translated text.
    let onTranslated: (String) -> Void

    @State private var showSheet = false

    var body: some View {
        Group {
            if bordered {
                Button { showSheet = true } label: {
                    Label("Translate…", systemImage: "globe")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button { showSheet = true } label: {
                    Label("Translate…", systemImage: "globe")
                        .font(font)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .help(helpText)
        .sheet(isPresented: $showSheet) {
            QuickTranslateSheet(sourceText: sourceText(), onTranslated: onTranslated)
        }
    }
}
