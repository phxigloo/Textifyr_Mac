import SwiftUI
import AppKit
import Combine

// MARK: - Format State

/// Shared state between FormattingToolbar and the RichTextEditor coordinator.
/// Holds the current format at the cursor and exposes action methods.
final class TextFormatState: ObservableObject {
    weak var textView: NSTextView?

    @Published var isBold          = false
    @Published var isItalic        = false
    @Published var isUnderline     = false
    @Published var isStrikethrough = false
    @Published var fontSize: CGFloat    = 13
    @Published var textColor: Color     = Color(nsColor: .labelColor)
    @Published var alignment: NSTextAlignment = .left
    @Published var isBulletList   = false
    @Published var isNumberedList = false
    @Published var isSuperscript  = false
    @Published var isSubscript    = false
    @Published var highlightColor: Color = Color(nsColor: .clear)

    // Prevents onChange(of: textColor) from re-applying color while we are syncing.
    private var isSyncing = false

    // MARK: Actions

    func applyBold()      { toggleFontTrait(.boldFontMask);   syncFromTextView() }
    func applyItalic()    { toggleFontTrait(.italicFontMask); syncFromTextView() }

    func applyStrikethrough() {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let isOn = (tv.typingAttributes[.strikethroughStyle] as? Int).map { $0 != 0 } ?? false
        let value = isOn ? 0 : NSUnderlineStyle.single.rawValue
        if range.length > 0 {
            tv.textStorage?.addAttribute(.strikethroughStyle, value: value, range: range)
        } else {
            tv.typingAttributes[.strikethroughStyle] = value
        }
        syncFromTextView()
    }

    @Published var isFindBarVisible  = false
    @Published var findMatchCount    = 0
    @Published var findCurrentMatch  = 0

    func performFind(_ action: NSTextFinder.Action) {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        final class TaggedSender: NSObject {
            private let _tag: Int
            init(_ t: Int) { _tag = t }
            @objc var tag: Int { _tag }
        }
        tv.performTextFinderAction(TaggedSender(action.rawValue))
        if action == .nextMatch || action == .previousMatch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.refreshFindCount()
            }
        }
    }

    func toggleFind() {
        isFindBarVisible.toggle()
        performFind(isFindBarVisible ? .showFindInterface : .hideFindInterface)
        if !isFindBarVisible { findMatchCount = 0; findCurrentMatch = 0 }
    }

    func refreshFindCount() {
        guard let tv = textView else { return }
        let searchText = NSPasteboard(name: .find).string(forType: .string) ?? ""
        guard !searchText.isEmpty else { findMatchCount = 0; findCurrentMatch = 0; return }
        let text = tv.string
        guard let regex = try? NSRegularExpression(
            pattern: NSRegularExpression.escapedPattern(for: searchText),
            options: .caseInsensitive) else { return }
        let nsText    = text as NSString
        let allRanges = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        findMatchCount   = allRanges.count
        let sel          = tv.selectedRange()
        findCurrentMatch = (allRanges.firstIndex { NSEqualRanges($0.range, sel) } ?? -1) + 1
    }

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

    func toggleList(ordered: Bool) {
        guard let tv = textView, let ts = tv.textStorage, ts.length > 0 else { return }
        let range = tv.selectedRange()
        let fullStr = tv.string as NSString
        let paraRange = fullStr.paragraphRange(for: range)
        let existingStyle = ts.attribute(.paragraphStyle, at: paraRange.location, effectiveRange: nil) as? NSParagraphStyle
        let currentLists = existingStyle?.textLists ?? []
        let desiredFormat: NSTextList.MarkerFormat = ordered ? .decimal : .disc
        let alreadyThisKind = currentLists.first?.markerFormat == desiredFormat
        ts.beginEditing()
        if alreadyThisKind {
            let plain = NSMutableParagraphStyle()
            ts.addAttribute(.paragraphStyle, value: plain, range: paraRange)
        } else {
            let list = NSTextList(markerFormat: desiredFormat, options: 0)
            let ps = NSMutableParagraphStyle()
            ps.textLists = [list]
            ps.headIndent = 18
            ps.firstLineHeadIndent = 0
            ts.addAttribute(.paragraphStyle, value: ps, range: paraRange)
        }
        ts.endEditing()
        syncFromTextView()
    }

    func changeIndent(by delta: CGFloat) {
        guard let tv = textView, let ts = tv.textStorage, ts.length > 0 else { return }
        let range = tv.selectedRange()
        let fullStr = tv.string as NSString
        let paraRange = fullStr.paragraphRange(for: range)
        ts.beginEditing()
        ts.enumerateAttribute(.paragraphStyle, in: paraRange, options: []) { val, r, _ in
            let ps = (val as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            ps.headIndent           = max(0, ps.headIndent + delta)
            ps.firstLineHeadIndent  = max(0, ps.firstLineHeadIndent + delta)
            ts.addAttribute(.paragraphStyle, value: ps, range: r)
        }
        ts.endEditing()
    }

    func applySuperscript() {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let current = (tv.typingAttributes[.superscript] as? Int) ?? 0
        let newVal  = current == 1 ? 0 : 1
        if range.length > 0 {
            tv.textStorage?.addAttribute(.superscript, value: newVal, range: range)
        } else {
            tv.typingAttributes[.superscript] = newVal
        }
        isSuperscript = newVal == 1
        if isSuperscript { isSubscript = false }
        syncFromTextView()
    }

    func applySubscript() {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let current = (tv.typingAttributes[.superscript] as? Int) ?? 0
        let newVal  = current == -1 ? 0 : -1
        if range.length > 0 {
            tv.textStorage?.addAttribute(.superscript, value: newVal, range: range)
        } else {
            tv.typingAttributes[.superscript] = newVal
        }
        isSubscript = newVal == -1
        if isSubscript { isSuperscript = false }
        syncFromTextView()
    }

    func applyHighlight() {
        guard let tv = textView else { return }
        let ns = NSColor(highlightColor)
        let range = tv.selectedRange()
        if range.length > 0 {
            if ns.alphaComponent < 0.01 {
                tv.textStorage?.removeAttribute(.backgroundColor, range: range)
            } else {
                tv.textStorage?.addAttribute(.backgroundColor, value: ns, range: range)
            }
        } else {
            if ns.alphaComponent < 0.01 {
                tv.typingAttributes.removeValue(forKey: .backgroundColor)
            } else {
                tv.typingAttributes[.backgroundColor] = ns
            }
        }
    }

    func clearHighlight() {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length > 0 {
            tv.textStorage?.removeAttribute(.backgroundColor, range: range)
        } else {
            tv.typingAttributes.removeValue(forKey: .backgroundColor)
        }
        highlightColor = Color(nsColor: .clear)
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

        if let ss = attrs[.strikethroughStyle] as? Int {
            isStrikethrough = ss != 0
        } else {
            isStrikethrough = false
        }

        if let color = attrs[.foregroundColor] as? NSColor {
            textColor = Color(nsColor: color)
        }

        if let para = attrs[.paragraphStyle] as? NSParagraphStyle {
            alignment = para.alignment == .natural ? .left : para.alignment
        }

        let lists = (attrs[.paragraphStyle] as? NSParagraphStyle)?.textLists ?? []
        isBulletList   = lists.first?.markerFormat == .disc
        isNumberedList = lists.first?.markerFormat == .decimal

        let superVal = (attrs[.superscript] as? Int) ?? 0
        isSuperscript = superVal == 1
        isSubscript   = superVal == -1

        if let bg = attrs[.backgroundColor] as? NSColor {
            isSyncing = true
            highlightColor = Color(nsColor: bg)
            isSyncing = false
        } else {
            isSyncing = true
            highlightColor = Color(nsColor: .clear)
            isSyncing = false
        }
    }
}

// MARK: - Formatting Toolbar

struct FormattingToolbar: View {
    @ObservedObject var fmt: TextFormatState

    var body: some View {
        HStack(spacing: 6) {
            // Bold / Italic / Underline / Strikethrough
            HStack(spacing: 1) {
                fmtBtn("bold",            on: fmt.isBold,          tip: "Bold (⌘B)")      { fmt.applyBold() }
                fmtBtn("italic",          on: fmt.isItalic,        tip: "Italic (⌘I)")    { fmt.applyItalic() }
                fmtBtn("underline",       on: fmt.isUnderline,     tip: "Underline (⌘U)") { fmt.applyUnderline() }
                fmtBtn("strikethrough",   on: fmt.isStrikethrough, tip: "Strikethrough")  { fmt.applyStrikethrough() }
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

            // Alignment
            HStack(spacing: 1) {
                fmtBtn("text.alignleft",   on: fmt.alignment == .left,      tip: "Align Left")   { fmt.applyAlignment(.left) }
                fmtBtn("text.aligncenter", on: fmt.alignment == .center,    tip: "Align Centre") { fmt.applyAlignment(.center) }
                fmtBtn("text.alignright",  on: fmt.alignment == .right,     tip: "Align Right")  { fmt.applyAlignment(.right) }
                fmtBtn("text.justify",     on: fmt.alignment == .justified, tip: "Justify")      { fmt.applyAlignment(.justified) }
            }

            sep

            // Lists and indentation — single menu button keeps toolbar compact
            Menu {
                Button { fmt.toggleList(ordered: false) } label: {
                    Label(fmt.isBulletList ? "Remove Bullet List" : "Bullet List",
                          systemImage: fmt.isBulletList ? "list.bullet.circle.fill" : "list.bullet")
                }
                Button { fmt.toggleList(ordered: true) } label: {
                    Label(fmt.isNumberedList ? "Remove Numbered List" : "Numbered List",
                          systemImage: fmt.isNumberedList ? "list.number.circle.fill" : "list.number")
                }
                Divider()
                Button { fmt.changeIndent(by:  18) } label: { Label("Indent More", systemImage: "increase.indent") }
                Button { fmt.changeIndent(by: -18) } label: { Label("Outdent",     systemImage: "decrease.indent") }
            } label: {
                Image(systemName: (fmt.isBulletList || fmt.isNumberedList) ? "list.bullet.circle.fill" : "list.dash")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 22)
                    .background(
                        (fmt.isBulletList || fmt.isNumberedList) ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4)
                    )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Lists and indentation")

            sep

            // Superscript / Subscript
            HStack(spacing: 1) {
                Button { fmt.applySuperscript() } label: {
                    Text("x²")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 22)
                        .background(
                            fmt.isSuperscript ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .buttonStyle(.borderless)
                .help("Superscript")

                Button { fmt.applySubscript() } label: {
                    Text("x₂")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 22)
                        .background(
                            fmt.isSubscript ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .buttonStyle(.borderless)
                .help("Subscript")
            }

            sep

            // Text colour: icon + swatch
            HStack(spacing: 6) {
                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .center)
                ColorPicker("", selection: $fmt.textColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 26, height: 20)
                    .help("Text colour")
                    .onChange(of: fmt.textColor) { _, _ in fmt.applyTextColor() }
            }
            .padding(.horizontal, 2)

            sep

            // Highlight colour: icon + swatch + clear
            HStack(spacing: 6) {
                Image(systemName: "highlighter")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .center)
                ColorPicker("", selection: $fmt.highlightColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 26, height: 20)
                    .help("Highlight colour")
                    .onChange(of: fmt.highlightColor) { _, _ in fmt.applyHighlight() }
                Button {
                    fmt.clearHighlight()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("Clear highlight")
            }
            .padding(.horizontal, 2)

            Spacer()

            fmtBtn("textformat", tip: "Fonts panel") { NSFontManager.shared.orderFrontFontPanel(nil) }

            sep

            HStack(spacing: 1) {
                fmtBtn("magnifyingglass", on: fmt.isFindBarVisible,
                       tip: fmt.isFindBarVisible ? "Hide Find" : "Find (⌘F)") { fmt.toggleFind() }
                if fmt.isFindBarVisible && fmt.findMatchCount > 0 {
                    Text(fmt.findCurrentMatch > 0
                         ? "\(fmt.findCurrentMatch)/\(fmt.findMatchCount)"
                         : "\(fmt.findMatchCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 34)
                        .transition(.opacity)
                }
                fmtBtn("arrow.up",               tip: "Previous (⇧⌘G)")  { fmt.performFind(.previousMatch) }
                fmtBtn("arrow.down",             tip: "Next (⌘G)")        { fmt.performFind(.nextMatch) }
                fmtBtn("arrow.left.arrow.right", tip: "Find & Replace")   { fmt.performFind(.showReplaceInterface) }
            }
            .animation(.easeInOut(duration: 0.15), value: fmt.findMatchCount)
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
        tv.usesFindBar              = true
        tv.isAutomaticLinkDetectionEnabled = true
        tv.textContainerInset       = NSSize(width: 20, height: 20)
        tv.backgroundColor          = .textBackgroundColor
        tv.textColor                = .labelColor   // adaptive default — overridden per-char by RTF
        tv.typingAttributes[.foregroundColor] = NSColor.labelColor
        tv.delegate                 = coordinator
        coordinator.textView        = tv
        formatState.textView        = tv
    }

    private func loadContent(into tv: NSTextView, data: Data?) {
        // Suppress delegate during programmatic load to prevent textDidChange from
        // publishing state changes while SwiftUI's updateNSView is still on the stack.
        let savedDelegate = tv.delegate
        tv.delegate = nil
        defer { tv.delegate = savedDelegate }
        guard let data else { tv.string = ""; return }

        // Try RTFD first (preserves NSTextAttachment images from Combine path),
        // fall back to plain RTF for AI-formatted text-only output.
        let raw: NSAttributedString?
        if let rtfd = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil) {
            raw = rtfd
        } else {
            raw = NSAttributedString(rtf: data, documentAttributes: nil)
        }
        if let attr = raw {
            let mutable = NSMutableAttributedString(attributedString: attr)
            let fullRange = NSRange(location: 0, length: mutable.length)

            // IMPORTANT: NSLayoutManager renders text with NO foreground attribute as black,
            // regardless of tv.textColor. Removing near-black attrs leaves those ranges
            // black too. The correct fix: collect intentional saturated colours first,
            // replace the entire document with labelColor, then restore intentional colours.

            var intentional: [(NSColor, NSRange)] = []
            mutable.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { val, range, _ in
                guard let nsOrig = val as? NSColor,
                      let ns = nsOrig.usingColorSpace(.genericRGB)
                              ?? nsOrig.usingColorSpace(.sRGB)
                              ?? nsOrig.usingColorSpace(.deviceRGB) else { return }
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
                ns.getRed(&r, green: &g, blue: &b, alpha: nil)
                // Threshold 0.20/0.80 catches labelColor-serialised greys in both modes
                // while preserving saturated intentional colours (red, blue, green…)
                let mono = (r < 0.20 && g < 0.20 && b < 0.20) || (r > 0.80 && g > 0.80 && b > 0.80)
                if !mono { intentional.append((nsOrig, range)) }
            }

            // 1. Paint everything with the adaptive label colour
            mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
            // 2. Restore intentional saturated colours
            for (color, range) in intentional {
                mutable.addAttribute(.foregroundColor, value: color, range: range)
            }

            tv.textStorage?.setAttributedString(mutable)
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
            let attr  = tv.attributedString()
            let range = NSRange(location: 0, length: attr.length)

            // Preserve image attachments by saving as RTFD when present.
            var hasAttachments = false
            attr.enumerateAttribute(.attachment, in: range, options: []) { val, _, stop in
                if val != nil { hasAttachments = true; stop.pointee = true }
            }
            let data: Data?
            if hasAttachments {
                data = try? attr.data(from: range,
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            } else {
                data = attr.rtf(from: range,
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            }
            lastKnownData = data
            DispatchQueue.main.async { [weak self] in
                self?.parent.rtfData = data
                self?.parent.formatState.syncFromTextView()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                self?.parent.formatState.syncFromTextView()
                if self?.parent.formatState.isFindBarVisible == true {
                    self?.parent.formatState.refreshFindCount()
                }
            }
        }
    }
}
