import Foundation
import AppKit

/// Converts a Markdown string to RTF data via an HTML intermediate.
///
/// AppKit's HTML importer correctly renders h1–h6 at distinct font sizes,
/// <hr> as a rule, <ul>/<ol> with real indentation, <b>, <i>, <del>, <code>
/// and <a> links — far more faithfully than AttributedString(markdown:), which
/// loses most formatting when bridged to NSAttributedString for RTF export.
enum MarkdownRenderer {

    // MARK: - Public API

    static func toRTF(_ markdown: String) -> Data? {
        let html = toHTML(markdown)
        guard let htmlData = html.data(using: .utf8) else { return nil }
        guard let attr = try? NSAttributedString(
            data: htmlData,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        ) else { return nil }

        // Replace near-black / near-white foreground colours with labelColor so
        // the document looks correct in both light and dark mode.
        let mutable = NSMutableAttributedString(attributedString: attr)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttribute(.foregroundColor, in: full) { val, r, _ in
            guard let ns = (val as? NSColor)
                    .flatMap({ $0.usingColorSpace(.genericRGB) ?? $0.usingColorSpace(.sRGB) }) else { return }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
            ns.getRed(&red, green: &green, blue: &blue, alpha: nil)
            let mono = (red < 0.2 && green < 0.2 && blue < 0.2)
                    || (red > 0.8 && green > 0.8 && blue > 0.8)
            if mono { mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: r) }
        }
        return mutable.rtf(from: full,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    // MARK: - Markdown → HTML

    static func toHTML(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var html: [String] = []
        var i = 0
        var inCodeBlock = false
        var codeLanguage = ""
        var codeLines: [String] = []
        var listKind: ListKind? = nil   // currently open list (single level)
        var inBlockquote = false

        func closeList() {
            if let k = listKind { html.append(k == .ordered ? "</ol>" : "</ul>"); listKind = nil }
        }
        func closeBlockquote() {
            if inBlockquote { html.append("</blockquote>"); inBlockquote = false }
        }

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // ── Fenced code block ─────────────────────────────────────────
            let isFence = raw.hasPrefix("```") || raw.hasPrefix("~~~")
            if isFence {
                if inCodeBlock {
                    inCodeBlock = false
                    let body = codeLines.map { esc($0) }.joined(separator: "\n")
                    let langAttr = codeLanguage.isEmpty ? "" : " class=\"language-\(esc(codeLanguage))\""
                    html.append("<pre><code\(langAttr)>\(body)</code></pre>")
                    codeLines = []; codeLanguage = ""
                } else {
                    closeList(); closeBlockquote()
                    inCodeBlock = true
                    let fence = raw.hasPrefix("```") ? "```" : "~~~"
                    codeLanguage = String(raw.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                }
                i += 1; continue
            }
            if inCodeBlock { codeLines.append(raw); i += 1; continue }

            // ── Blank line ────────────────────────────────────────────────
            if trimmed.isEmpty {
                closeList(); closeBlockquote()
                i += 1; continue
            }

            // ── Horizontal rule (--- / *** / ___ alone on a line) ─────────
            if isHRule(trimmed) {
                closeList(); closeBlockquote()
                html.append("<hr>")
                i += 1; continue
            }

            // ── ATX Heading (#…) ──────────────────────────────────────────
            if let (level, heading) = atxHeading(trimmed) {
                closeList(); closeBlockquote()
                html.append("<h\(level)>\(inline(heading))</h\(level)>")
                i += 1; continue
            }

            // ── Setext heading (underlined with = or -) ────────────────────
            if i + 1 < lines.count {
                let nextTrim = lines[i + 1].trimmingCharacters(in: .whitespaces)
                let isEq  = nextTrim.count >= 2 && nextTrim.allSatisfy({ $0 == "=" })
                let isDash = nextTrim.count >= 2 && nextTrim.allSatisfy({ $0 == "-" }) && !isHRule(nextTrim)
                if isEq  { closeList(); closeBlockquote(); html.append("<h1>\(inline(trimmed))</h1>"); i += 2; continue }
                if isDash { closeList(); closeBlockquote(); html.append("<h2>\(inline(trimmed))</h2>"); i += 2; continue }
            }

            // ── Blockquote ────────────────────────────────────────────────
            if trimmed.hasPrefix(">") {
                closeList()
                if !inBlockquote { html.append("<blockquote>"); inBlockquote = true }
                let content = trimmed.hasPrefix("> ") ? String(trimmed.dropFirst(2)) : String(trimmed.dropFirst())
                html.append("<p>\(inline(content))</p>")
                i += 1; continue
            } else {
                closeBlockquote()
            }

            // ── Unordered list ────────────────────────────────────────────
            if let item = ulItem(trimmed) {
                if listKind == nil   { html.append("<ul>"); listKind = .unordered }
                if listKind == .ordered { html.append("</ol><ul>"); listKind = .unordered }
                html.append("<li>\(inline(item))</li>")
                i += 1; continue
            }

            // ── Ordered list ──────────────────────────────────────────────
            if let item = olItem(trimmed) {
                if listKind == nil    { html.append("<ol>"); listKind = .ordered }
                if listKind == .unordered { html.append("</ul><ol>"); listKind = .ordered }
                html.append("<li>\(inline(item))</li>")
                i += 1; continue
            }

            // ── Regular paragraph (gather consecutive lines) ───────────────
            closeList()
            var paraLines: [String] = [trimmed]
            while i + 1 < lines.count {
                let nt = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if nt.isEmpty { break }
                if atxHeading(nt) != nil || isHRule(nt) { break }
                if ulItem(nt) != nil || olItem(nt) != nil { break }
                if nt.hasPrefix(">") { break }
                if lines[i + 1].hasPrefix("```") || lines[i + 1].hasPrefix("~~~") { break }
                paraLines.append(nt)
                i += 1
            }
            html.append("<p>\(inline(paraLines.joined(separator: " ")))</p>")
            i += 1
        }

        closeList(); closeBlockquote()
        if inCodeBlock, !codeLines.isEmpty {
            html.append("<pre><code>\(codeLines.map { esc($0) }.joined(separator: "\n"))</code></pre>")
        }

        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
          body { font-family: -apple-system, Helvetica Neue, sans-serif; font-size: 13px; }
          h1 { font-size: 2em; }   h2 { font-size: 1.6em; } h3 { font-size: 1.4em; }
          h4 { font-size: 1.2em; } h5 { font-size: 1.1em; } h6 { font-size: 1em; font-style: italic; }
          hr { border: none; border-top: 1px solid #999; margin: 1em 0; }
          pre { background: #f5f5f5; padding: 8px; border-radius: 4px; }
          code { font-family: Menlo, Monaco, monospace; font-size: 0.9em; background: #f5f5f5; padding: 0 2px; }
          pre code { background: none; padding: 0; }
          blockquote { margin: 0 0 0 1em; padding-left: 0.8em; border-left: 3px solid #ccc; color: #555; }
          ul, ol { padding-left: 2em; }
          a { color: #0070c9; }
        </style>
        </head><body>\(html.joined(separator: "\n"))</body></html>
        """
    }

    // MARK: - Inline formatting (HTML-escape first, then apply patterns via NSRegularExpression)

    private static func inline(_ text: String) -> String {
        // 1. HTML-escape raw text so < > & are safe.
        var s = esc(text)
        // 2. Protect backtick code spans from further pattern matching.
        s = inlineCode(s)
        // 3. Images before links (![alt](url) → [alt])
        s = re(s, "!\\[([^\\]]*)\\]\\([^)]+\\)", "<em>[$1]</em>")
        // 4. Links
        s = re(s, "\\[([^\\]]+)\\]\\(([^)]+)\\)", "<a href=\"$2\">$1</a>")
        // 5. Bold: **text** or __text__
        s = re(s, "\\*\\*(.+?)\\*\\*", "<b>$1</b>")
        s = re(s, "__(.+?)__",          "<b>$1</b>")
        // 6. Italic: *text* (not part of **), _text_ (not part of __)
        //    NSRegularExpression supports lookbehind (ICU syntax).
        s = re(s, "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)", "<i>$1</i>")
        s = re(s, "(?<!_)_(?!_)(.+?)(?<!_)_(?!_)",             "<i>$1</i>")
        // 7. Strikethrough
        s = re(s, "~~(.+?)~~", "<del>$1</del>")
        return s
    }

    /// Wraps backtick spans in <code>…</code>. Operates on already-escaped text.
    private static func inlineCode(_ text: String) -> String {
        var result = ""
        var rest = text[...]
        while let open = rest.range(of: "`") {
            result += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            if let close = after.range(of: "`") {
                result += "<code>\(after[..<close.lowerBound])</code>"
                rest = after[close.upperBound...]
            } else {
                result += "`" + after
                return result
            }
        }
        result += rest
        return String(result)
    }

    // MARK: - Helpers

    private enum ListKind { case unordered, ordered }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&",  with: "&amp;")
         .replacingOccurrences(of: "<",  with: "&lt;")
         .replacingOccurrences(of: ">",  with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func re(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Returns true when the trimmed line is a thematic break (---, ***, ___).
    static func isHRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        return stripped.count >= 3 &&
            (stripped.allSatisfy({ $0 == "-" }) ||
             stripped.allSatisfy({ $0 == "*" }) ||
             stripped.allSatisfy({ $0 == "_" }))
    }

    private static func atxHeading(_ trimmed: String) -> (Int, String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for ch in trimmed { if ch == "#" { level += 1 } else { break } }
        guard level <= 6 else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.hasPrefix(" ") || rest.isEmpty else { return nil }
        return (level, String(rest.drop(while: { $0 == " " })))
    }

    private static func ulItem(_ trimmed: String) -> String? {
        for prefix in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(prefix) { return String(trimmed.dropFirst(prefix.count)) }
        }
        return nil
    }

    private static func olItem(_ trimmed: String) -> String? {
        guard let dot = trimmed.firstIndex(of: ".") else { return nil }
        let num = trimmed[..<dot]
        guard !num.isEmpty, num.allSatisfy({ $0.isNumber }) else { return nil }
        let after = trimmed[trimmed.index(after: dot)...]
        guard after.hasPrefix(" ") else { return nil }
        return String(after.dropFirst())
    }
}
