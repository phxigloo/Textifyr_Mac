import SwiftUI
import AppKit
import Combine

// MARK: - Format State

/// Shared state between FormattingToolbar and the RichTextEditor coordinator.
/// Holds the current format at the cursor and exposes action methods.
final class TextFormatState: ObservableObject {
    weak var textView: NSTextView?

    @Published var isBold      = false
    @Published var isItalic    = false
    @Published var isUnderline = false
    @Published var fontSize: CGFloat    = 13
    @Published var textColor: Color     = Color(nsColor: .labelColor)
    @Published var alignment: NSTextAlignment = .left

    // Prevents onChange(of: textColor) from re-applying color while we are syncing.
    private var isSyncing = false

    // MARK: Actions

    func applyBold()      { toggleFontTrait(.boldFontMask);   syncFromTextView() }
    func applyItalic()    { toggleFontTrait(.italicFontMask); syncFromTextView() }

    func applyUnderline() {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let isOn = (tv.typingAttributes[.underlineStyle] as? Int).map { $0 != 0 } ?? false
        let value = isOn ? 0 : NSUnderlineStyle.single.rawValue
        if range.length > 0 {
            tv.textStorage?.addAttribute(.underlineStyle, value: value, range: range)
        } else {
            tv.typingAttributes[.underlineStyle] = value
        }
        syncFromTextView()
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length > 0 {
            tv.textStorage?.beginEditing()
            tv.textStorage?.enumerateAttribute(.font, in: range, options: []) { val, r, _ in
                guard let font = val as? NSFont else { return }
                let has = NSFontManager.shared.traits(of: font).contains(trait)
                let newFont = has
                    ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
                    : NSFontManager.shared.convert(font, toHaveTrait: trait)
                tv.textStorage?.addAttribute(.font, value: newFont, range: r)
            }
            tv.textStorage?.endEditing()
        } else if let font = tv.typingAttributes[.font] as? NSFont {
            let has = NSFontManager.shared.traits(of: font).contains(trait)
            let newFont = has
                ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
                : NSFontManager.shared.convert(font, toHaveTrait: trait)
            tv.typingAttributes[.font] = newFont
        }
    }

    func applyTextColor() {
        guard !isSyncing, let tv = textView else { return }
        let ns = NSColor(textColor)
        let range = tv.selectedRange()
        if range.length > 0 {
            tv.textStorage?.addAttribute(.foregroundColor, value: ns, range: range)
        } else {
            tv.typingAttributes[.foregroundColor] = ns
        }
    }

    func changeFontSize(by delta: CGFloat) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length > 0 {
            tv.textStorage?.beginEditing()
            tv.textStorage?.enumerateAttribute(.font, in: range, options: []) { val, r, _ in
                if let font = val as? NSFont,
                   let newFont = NSFont(descriptor: font.fontDescriptor, size: max(6, font.pointSize + delta)) {
                    tv.textStorage?.addAttribute(.font, value: newFont, range: r)
                }
            }
            tv.textStorage?.endEditing()
        } else if let font = tv.typingAttributes[.font] as? NSFont,
                  let newFont = NSFont(descriptor: font.fontDescriptor, size: max(6, font.pointSize + delta)) {
            tv.typingAttributes[.font] = newFont
            fontSize = newFont.pointSize
        }
    }

    func applyAlignment(_ align: NSTextAlignment) {
        guard let tv = textView else { return }
        tv.setAlignment(align, range: tv.selectedRange())
        alignment = align
    }

    // MARK: Sync from text view

    /// Refreshes published state to match the current cursor position / typing attributes.
    func syncFromTextView() {
        guard let tv = textView else { return }
        isSyncing = true
        defer { isSyncing = false }

        let attrs = tv.typingAttributes

        if let font = attrs[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            isBold   = traits.contains(.boldFontMask)
            isItalic = traits.contains(.italicFontMask)
            fontSize = font.pointSize
        }

        if let us = attrs[.underlineStyle] as? Int {
            isUnderline = us != 0
        } else {
            isUnderline = false
        }

        if let color = attrs[.foregroundColor] as? NSColor {
            textColor = Color(nsColor: color)
        }

        if let para = attrs[.paragraphStyle] as? NSParagraphStyle {
            alignment = para.alignment == .natural ? .left : para.alignment
        }
    }
}

// MARK: - Formatting Toolbar

struct FormattingToolbar: View {
    @ObservedObject var fmt: TextFormatState

    var body: some View {
        HStack(spacing: 6) {
            // Bold / Italic / Underline
            HStack(spacing: 1) {
                fmtBtn("bold",      on: fmt.isBold,      tip: "Bold (⌘B)")      { fmt.applyBold() }
                fmtBtn("italic",    on: fmt.isItalic,    tip: "Italic (⌘I)")    { fmt.applyItalic() }
                fmtBtn("underline", on: fmt.isUnderline, tip: "Underline (⌘U)") { fmt.applyUnderline() }
            }

            sep

            // Font size
            HStack(spacing: 3) {
                fmtBtn("textformat.size.smaller", tip: "Decrease font size") { fmt.changeFontSize(by: -1) }
                Text(String(format: "%.0f", fmt.fontSize))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                fmtBtn("textformat.size.larger", tip: "Increase font size")  { fmt.changeFontSize(by:  1) }
            }

            sep

            // Text colour
            ColorPicker("", selection: $fmt.textColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 26, height: 20)
                .help("Text colour")
                .onChange(of: fmt.textColor) { _, _ in fmt.applyTextColor() }

            sep

            // Alignment
            HStack(spacing: 1) {
                fmtBtn("text.alignleft",   on: fmt.alignment == .left,      tip: "Align Left")   { fmt.applyAlignment(.left) }
                fmtBtn("text.aligncenter", on: fmt.alignment == .center,    tip: "Align Centre") { fmt.applyAlignment(.center) }
                fmtBtn("text.alignright",  on: fmt.alignment == .right,     tip: "Align Right")  { fmt.applyAlignment(.right) }
                fmtBtn("text.justify",     on: fmt.alignment == .justified, tip: "Justify")      { fmt.applyAlignment(.justified) }
            }

            Spacer()

            Button("Fonts") { NSFontManager.shared.orderFrontFontPanel(nil) }
                .buttonStyle(.bordered)
                .font(.caption)
                .help("Show the Fonts panel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var sep: some View { Divider().frame(height: 18) }

    @ViewBuilder
    private func fmtBtn(_ img: String, on active: Bool = false, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: img)
                .font(.system(size: 12))
                .frame(width: 26, height: 22)
                .background(
                    active ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.borderless)
        .help(tip)
    }
}

// MARK: - Rich Text Editor (NSViewRepresentable)

/// An editable or read-only rich-text view backed by NSTextView.
/// Binds to `rtfData` (nil = empty); saves back whenever the user edits.
struct RichTextEditor: NSViewRepresentable {
    @Binding var rtfData: Data?
    var isEditable: Bool = true
    @ObservedObject var formatState: TextFormatState

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let tv = scrollView.documentView as? NSTextView else { return scrollView }

        configure(tv, coordinator: context.coordinator)
        loadContent(into: tv, data: rtfData)
        context.coordinator.lastKnownData = rtfData

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }

        // Re-wire references in case the view is recycled
        context.coordinator.parent = self
        context.coordinator.textView = tv
        formatState.textView = tv
        tv.isEditable = isEditable

        // Only replace content when data changed externally (not by our own edits)
        if rtfData != context.coordinator.lastKnownData {
            loadContent(into: tv, data: rtfData)
            context.coordinator.lastKnownData = rtfData
        }
    }

    // MARK: - Helpers

    private func configure(_ tv: NSTextView, coordinator: Coordinator) {
        tv.isEditable               = isEditable
        tv.isRichText               = true
        tv.allowsUndo               = true
        tv.usesFontPanel            = true
        tv.isAutomaticLinkDetectionEnabled = true
        tv.textContainerInset       = NSSize(width: 20, height: 20)
        tv.backgroundColor          = .textBackgroundColor
        tv.delegate                 = coordinator
        coordinator.textView        = tv
        formatState.textView        = tv
    }

    private func loadContent(into tv: NSTextView, data: Data?) {
        if let data, let attr = NSAttributedString(rtf: data, documentAttributes: nil) {
            tv.textStorage?.setAttributedString(attr)
        } else {
            tv.string = ""
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var lastKnownData: Data?
        weak var textView: NSTextView?

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let attr = tv.attributedString()
            let data = attr.rtf(
                from: NSRange(location: 0, length: attr.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            lastKnownData = data
            // Defer to avoid mutating binding during a view update pass
            DispatchQueue.main.async { [weak self] in
                self?.parent.rtfData = data
                self?.parent.formatState.syncFromTextView()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                self?.parent.formatState.syncFromTextView()
            }
        }
    }
}
