import AppKit

/// The HTML people write inside Markdown, shown the way GitHub and HackMD show it.
///
/// `convert` runs on the source before anything else and rewrites known tags:
/// - Inline tags (`<b>`, `<span style="color: red">`, `<a href>` …) become markers around their
///   content, with a `Style` the renderer applies once the text is laid out (see
///   `MarkdownRenderer.applyHTMLStyles`).
/// - Block tags become Markdown the rest of the pipeline already draws: headings, lists, tables,
///   code blocks, rules, and HackMD-style `:::` boxes for alignment, quotes and `<details>`.
/// Tags it doesn't know, such as `List<T>`, stay as typed, and code is left alone.
enum HTML {
    /// One inline element's look.
    struct Style {
        var bold = false, italic = false, underline = false, dotted = false, strike = false
        var raised = false, lowered = false, code = false   // raised: superscript, lowered: subscript
        var scale: CGFloat?
        var color: NSColor?, background: NSColor?
        var link: URL?, tooltip: String?
    }

    /// Marker characters: `open`, the style's number, `openEnd` … content … `close`.
    static let open: Character = "\u{E030}"
    static let openEnd: Character = "\u{E031}"
    static let close: Character = "\u{E032}"

    /// `:::` box kinds HackMD.rewrite turns into quotes, for aligned blocks and `<blockquote>`.
    static let centerBox = "menunote-center"
    static let rightBox = "menunote-right"
    static let quoteBox = "menunote-quote"

    /// A table cell with spans: `cellMarker` + "table,row,column,rowSpan,columnSpan,columns,header,align"
    /// + `cellMarkerEnd`, then the cell's content, as a paragraph of its own. Markdown tables can't
    /// span, so tables that do are laid out by the renderer from these.
    static let cellMarker: Character = "\u{E050}"
    static let cellMarkerEnd: Character = "\u{E051}"

    struct SpanningCell {
        var table = 0, row = 0, column = 0, rowSpan = 1, columnSpan = 1, columns = 1
        var header = false
        var alignment = NSTextAlignment.natural
    }

    /// Reads a cell marker's fields; nil if `text` doesn't start with one.
    static func spanningCell(_ text: String) -> (cell: SpanningCell, length: Int)? {
        guard text.first == cellMarker, let end = text.firstIndex(of: cellMarkerEnd) else { return nil }
        let fields = text[text.index(after: text.startIndex)..<end].split(separator: ",").map(String.init)
        guard fields.count == 8, let numbers = Optional(fields.prefix(6).compactMap { Int($0) }), numbers.count == 6 else { return nil }
        var cell = SpanningCell(table: numbers[0], row: numbers[1], column: numbers[2],
                                rowSpan: numbers[3], columnSpan: numbers[4], columns: numbers[5])
        cell.header = fields[6] == "1"
        cell.alignment = ["c": .center, "r": .right, "l": .left][fields[7]] ?? .natural
        return (cell, text.distance(from: text.startIndex, to: end) + 1)
    }

    static func convert(_ source: String) -> (String, [Style]) {
        // Most notes have no HTML; skip the work.
        guard source.contains("<") else { return (source, []) }
        let converter = Converter()
        converter.run(source.components(separatedBy: "\n"))
        return (converter.out.joined(separator: "\n"), converter.styles)
    }

    // MARK: - Tags

    private static let inlineTags: Set<String> = [
        "b", "strong", "i", "em", "cite", "var", "dfn", "u", "ins", "s", "strike", "del", "mark",
        "sup", "sub", "code", "tt", "samp", "kbd", "small", "big", "span", "font", "abbr", "acronym",
        "a", "q", "label", "time", "data",
    ]
    private static let wrapperTags: Set<String> = [
        "div", "p", "center", "section", "article", "header", "footer", "main", "nav", "aside",
        "figure", "figcaption", "address", "body", "html",
    ]
    private static let otherTags: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "hr", "br", "img", "ul", "ol", "li", "table", "thead",
        "tbody", "tfoot", "tr", "th", "td", "caption", "pre", "blockquote", "details", "summary",
        "script", "style", "head", "title", "meta", "link", "iframe", "video", "audio", "source",
        "input", "dl", "dt", "dd",
    ]
    /// Elements whose content is never shown.
    private static let hiddenTags: Set<String> = ["script", "style", "head", "title"]

    private static let tagPattern = try! NSRegularExpression(
        pattern: #"<(/?)([a-zA-Z][a-zA-Z0-9]*)((?:\s+[^<>]*?)?)\s*(/?)>"#)
    private static let attributePattern = try! NSRegularExpression(
        pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#)

    private enum Token {
        case text(String)
        case tag(name: String, closing: Bool, attributes: [String: String])
    }

    private static let codeSpan = try! NSRegularExpression(pattern: "(`+).*?\\1")

    /// A line's text and known tags, with inline code kept as text.
    private static func tokens(_ line: String) -> [Token] {
        var tokens: [Token] = []
        func scan(_ text: String) {
            let ns = text as NSString
            var start = 0
            for m in tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 2)).lowercased()
                guard inlineTags.contains(name) || wrapperTags.contains(name) || otherTags.contains(name) else { continue }
                if m.range.location > start {
                    tokens.append(.text(ns.substring(with: NSRange(location: start, length: m.range.location - start))))
                }
                tokens.append(.tag(name: name, closing: m.range(at: 1).length > 0,
                                   attributes: attributes(ns.substring(with: m.range(at: 3)))))
                start = NSMaxRange(m.range)
            }
            if start < ns.length { tokens.append(.text(ns.substring(from: start))) }
        }
        let ns = line as NSString
        var start = 0
        for code in codeSpan.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            scan(ns.substring(with: NSRange(location: start, length: code.range.location - start)))
            tokens.append(.text(ns.substring(with: code.range)))
            start = NSMaxRange(code.range)
        }
        scan(ns.substring(from: start))
        return tokens
    }

    private static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let ns = text as NSString
        for m in attributePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let value = (2...4).lazy.map { m.range(at: $0) }.first { $0.location != NSNotFound }
                .map { ns.substring(with: $0) } ?? ""
            result[ns.substring(with: m.range(at: 1)).lowercased()] = decodeEntities(value)
        }
        return result
    }

    /// For text the parser won't decode itself: attribute values and code.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": "\u{00A0}"] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        let numeric = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let ns = result as NSString
        var out = "", start = 0
        for m in numeric.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
            let hex = m.range(at: 1).length > 0
            guard let value = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10),
                  let scalar = Unicode.Scalar(value) else { continue }
            out += ns.substring(with: NSRange(location: start, length: m.range.location - start)) + String(Character(scalar))
            start = NSMaxRange(m.range)
        }
        return (out + ns.substring(from: start)).replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Styles

    /// The look of an inline element, or nil for one that only matters for its content.
    private static func style(_ name: String, _ attributes: [String: String]) -> Style? {
        var style = Style()
        switch name {
        case "b", "strong": style.bold = true
        case "i", "em", "cite", "var", "dfn": style.italic = true
        case "u", "ins": style.underline = true
        case "s", "strike", "del": style.strike = true
        case "mark": style.background = NSColor.systemYellow.withAlphaComponent(0.45)
        case "sup": style.raised = true
        case "sub": style.lowered = true
        case "code", "tt", "samp", "kbd": style.code = true
        case "small": style.scale = 0.85
        case "big": style.scale = 1.2
        case "a":
            guard let href = attributes["href"], !href.hasPrefix("#"),
                  let url = URL(string: href.replacingOccurrences(of: " ", with: "%20")) else { return nil }
            style.link = url
        case "font":
            style.color = attributes["color"].flatMap(color)
            if let size = attributes["size"].flatMap(Int.init) {
                style.scale = [1: 0.63, 2: 0.82, 3: 1, 4: 1.13, 5: 1.5, 6: 2, 7: 3][min(max(size, 1), 7)]
            }
        default:
            break
        }
        if let title = attributes["title"], !title.isEmpty {
            style.tooltip = title
            if name == "abbr" || name == "acronym" { style.dotted = true }
        }
        if let css = attributes["style"] { apply(css: css, to: &style) }
        let changed = style.bold || style.italic || style.underline || style.dotted || style.strike
            || style.raised || style.lowered || style.code || style.scale != nil || style.color != nil
            || style.background != nil || style.link != nil || style.tooltip != nil
        return changed ? style : nil
    }

    private static func apply(css: String, to style: inout Style) {
        for declaration in css.split(separator: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard pair.count == 2 else { continue }
            let (property, value) = (pair[0], pair[1])
            switch property {
            case "color": style.color = color(value) ?? style.color
            case "background", "background-color": style.background = color(value) ?? style.background
            case "font-weight": style.bold = value == "bold" || value == "bolder" || (Int(value) ?? 400) >= 600
            case "font-style": style.italic = value == "italic" || value == "oblique"
            case "text-decoration", "text-decoration-line":
                if value.contains("underline") { style.underline = true }
                if value.contains("line-through") { style.strike = true }
            case "font-size":
                if value.hasSuffix("em"), let n = Double(value.dropLast(2)) { style.scale = n }
                else if value.hasSuffix("%"), let n = Double(value.dropLast()) { style.scale = n / 100 }
                else if value.hasSuffix("px"), let n = Double(value.dropLast(2)) { style.scale = n / 16 }
                else if let n = ["small": 0.85, "x-small": 0.7, "large": 1.2, "x-large": 1.5, "xx-large": 2][value] {
                    style.scale = n
                }
            default:
                break
            }
        }
    }

    /// CSS colors: #rgb, #rrggbb, rgb()/rgba(), and the common names.
    static func color(_ text: String) -> NSColor? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
            NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
        }
        if value.hasPrefix("#") {
            var hex = String(value.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let n = Int(hex, radix: 16) else { return nil }
            return rgb(Double(n >> 16 & 0xFF), Double(n >> 8 & 0xFF), Double(n & 0xFF))
        }
        if value.hasPrefix("rgb") {
            let numbers = value.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
                .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count >= 3 else { return nil }
            return rgb(numbers[0], numbers[1], numbers[2], numbers.count > 3 ? numbers[3] : 1)
        }
        let names: [String: Int] = [
            "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF,
            "yellow": 0xFFFF00, "orange": 0xFFA500, "purple": 0x800080, "pink": 0xFFC0CB, "gray": 0x808080,
            "grey": 0x808080, "brown": 0xA52A2A, "cyan": 0x00FFFF, "aqua": 0x00FFFF, "magenta": 0xFF00FF,
            "fuchsia": 0xFF00FF, "teal": 0x008080, "navy": 0x000080, "maroon": 0x800000, "olive": 0x808000,
            "lime": 0x00FF00, "silver": 0xC0C0C0, "gold": 0xFFD700, "indigo": 0x4B0082, "violet": 0xEE82EE,
            "crimson": 0xDC143C, "coral": 0xFF7F50, "tomato": 0xFF6347, "skyblue": 0x87CEEB,
            "lightgray": 0xD3D3D3, "lightgrey": 0xD3D3D3, "darkgray": 0xA9A9A9, "darkgrey": 0xA9A9A9,
            "darkred": 0x8B0000, "darkgreen": 0x006400, "darkblue": 0x00008B, "lightblue": 0xADD8E6,
            "lightgreen": 0x90EE90, "orangered": 0xFF4500, "royalblue": 0x4169E1, "steelblue": 0x4682B4,
            "seagreen": 0x2E8B57, "salmon": 0xFA8072, "khaki": 0xF0E68C, "beige": 0xF5F5DC,
        ]
        return names[value].map { rgb(Double($0 >> 16 & 0xFF), Double($0 >> 8 & 0xFF), Double($0 & 0xFF)) }
    }

    // MARK: - Converting

    private final class Converter {
        var out: [String] = []
        var styles: [Style] = []

        private var line = ""                       // the output line being built
        private var fences = FenceTracker()
        private var inline: [(name: String, marked: Bool)] = []   // open inline elements
        private var lists: [(ordered: Bool, next: Int, indent: String, content: String)] = []
        private var wrappers: [Bool] = []           // open div/p/…: whether each opened a box
        private var details: [Int] = []             // out index of each open <details>' first line
        private var summary: String?                // a <summary>'s text, while inside one
        private var heading = false
        private var hidden: String?                 // inside <script>/<style>/…, until this tag closes
        private var pre: (language: String, text: String)?
        private struct Cell {
            var text = "", columnSpan = 1, rowSpan = 1, header = false
            var align: String?
        }
        private var table: (rows: [[Cell]], cell: Cell?, caption: String?)?
        private var tableCount = 0

        /// Inside these, line breaks in the source are only spaces, as in HTML.
        private var joiningLines: Bool { heading || !lists.isEmpty || table != nil || summary != nil }

        private static let quotePrefix = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]?)+"#)

        func run(_ lines: [String]) {
            for source in lines {
                if pre == nil, fences.isFence(source) || fences.inside {
                    flush()
                    out.append(source)
                    continue
                }
                if !source.contains("<"), pre == nil, hidden == nil, !joiningLines {
                    flush()
                    out.append(source)
                    continue
                }
                // HTML inside a quote: convert what follows the ">" markers, then quote what it became.
                let quote = (source as NSString).substring(with: Self.quotePrefix.firstMatch(
                    in: source, range: NSRange(location: 0, length: (source as NSString).length))?.range ?? NSRange())
                let before = out.count
                for token in tokens(String(source.dropFirst(quote.count))) { handle(token) }
                if var code = pre {
                    code.text += "\n"
                    pre = code
                } else if joiningLines {
                    emit(" ")
                } else {
                    flush()
                }
                if !quote.isEmpty {
                    for i in before..<out.count {
                        out[i] = out[i].isEmpty ? quote.trimmingCharacters(in: .whitespaces) : quote + out[i]
                    }
                }
            }
            flush()
        }

        // MARK: Output

        private func flush() {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { out.append(line) }
            line = ""
        }

        /// Ends the current block with a blank line, so what follows starts a new one.
        private func blank() {
            flush()
            if let last = out.last, !last.isEmpty { out.append("") }
        }

        private func emit(_ text: String) {
            if hidden != nil { return }
            if var code = pre {
                code.text += decodeEntities(text)
                pre = code
            } else if summary != nil {
                summary! += text
            } else if var t = table {
                if t.cell != nil {
                    t.cell!.text += text
                } else if t.caption != nil {
                    t.caption! += text
                }
                table = t
            } else {
                if line.isEmpty, let list = lists.last { line = list.content }
                line += text
            }
        }

        // MARK: Tokens

        private func handle(_ token: Token) {
            switch token {
            case .text(let text):
                emit(text)
            case .tag(let name, let closing, let attributes):
                if let hiding = hidden {
                    if closing, name == hiding { hidden = nil }
                    return
                }
                if pre != nil {
                    if closing && name == "pre" { closePre() }
                    else if name == "br" { emit("\n") }
                    else if name == "code", !closing, let language = language(attributes) { pre!.language = language }
                    return
                }
                if inlineTags.contains(name) {
                    closing ? closeInline(name) : openInline(name, attributes)
                } else {
                    closing ? closeBlock(name) : openBlock(name, attributes)
                }
            }
        }

        private func openInline(_ name: String, _ attributes: [String: String]) {
            if name == "q" { emit("“") }
            guard let style = style(name, attributes) else {
                inline.append((name, false))
                return
            }
            styles.append(style)
            emit("\(open)\(styles.count - 1)\(openEnd)")
            inline.append((name, true))
        }

        private func closeInline(_ name: String) {
            guard let index = inline.lastIndex(where: { $0.name == name }) else { return }
            // Close anything left open inside it too.
            for element in inline[index...].reversed() where element.marked { emit(String(close)) }
            inline.removeSubrange(index...)
            if name == "q" { emit("”") }
        }

        private func openBlock(_ name: String, _ attributes: [String: String]) {
            switch name {
            case "br":
                emit(summary != nil ? " " : "\u{2028}")
            case "img":
                guard let src = attributes["src"] else { return }
                let alt = (attributes["alt"] ?? "").replacingOccurrences(of: "]", with: "\\]")
                let size = [attributes["width"], attributes["height"]].map { $0.flatMap { Int($0) }.map(String.init) ?? "" }
                let sized = size == ["", ""] ? "" : " =\(size[0])x\(size[1])"
                emit("![\(alt)](\(src.replacingOccurrences(of: " ", with: "%20"))\(sized))")
            case "input":
                if attributes["type"] == "checkbox" { emit(attributes["checked"] != nil ? "☑ " : "☐ ") }
            case "iframe", "video", "audio":
                if let src = attributes["src"] {
                    emit("[▶ \(name == "audio" ? tr("音訊", "Audio") : tr("嵌入內容", "Embedded content"))](\(src))")
                }
                if name != "audio" { hidden = name }
            case _ where hiddenTags.contains(name):
                hidden = name
            case "hr":
                blank()
                out.append("---")
                out.append("")
            case "h1", "h2", "h3", "h4", "h5", "h6":
                blank()
                line = String(repeating: "#", count: Int(String(name.last!))!) + " "
                heading = true
            case "ul", "ol":
                flush()
                let indent = lists.last?.content ?? ""
                let start = attributes["start"].flatMap(Int.init) ?? 1
                lists.append((name == "ol", start, indent, indent))
            case "li":
                flush()
                guard var list = lists.popLast() else { line = "- "; return }
                let marker = list.ordered ? "\(list.next). " : "- "
                list.next += 1
                list.content = list.indent + String(repeating: " ", count: marker.count)
                line = list.indent + marker
                lists.append(list)
            case "dt":
                blank()
                line = "**"
            case "dd":
                flush()
                line = ": "
            case "table":
                blank()
                table = ([], nil, nil)
            case "caption":
                table?.caption = ""
            case "tr":
                table?.rows.append([])
            case "th", "td":
                guard table != nil else { return }
                if table!.rows.isEmpty { table!.rows.append([]) }
                table!.cell = Cell(columnSpan: max(1, attributes["colspan"].flatMap(Int.init) ?? 1),
                                   rowSpan: max(1, attributes["rowspan"].flatMap(Int.init) ?? 1),
                                   header: name == "th",
                                   align: (attributes["align"] ?? attributes["style"].flatMap(textAlign))?.lowercased())
            case "pre":
                blank()
                pre = ("", "")
            case "blockquote":
                blank()
                out.append(":::\(quoteBox)")
            case "details":
                blank()
                out.append(":::spoiler")
                details.append(out.count - 1)
            case "summary":
                summary = ""
            case _ where wrapperTags.contains(name):
                let align = (attributes["align"] ?? attributes["style"].flatMap(textAlign))?.lowercased()
                let box = name == "center" || align == "center" ? centerBox : align == "right" ? rightBox : nil
                name == "p" || box != nil ? blank() : flush()
                if let box { out.append(":::\(box)") }
                wrappers.append(box != nil)
            default:
                break
            }
        }

        private func closeBlock(_ name: String) {
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                heading = false
                blank()
            case "ul", "ol":
                flush()
                lists.removeLast(lists.isEmpty ? 0 : 1)
                if lists.isEmpty { blank() }
            case "li", "dd":
                flush()
            case "dt":
                line += "**"
                flush()
            case "th", "td":
                guard var t = table, var cell = t.cell else { return }
                cell.text = cell.text.trimmingCharacters(in: .whitespaces)
                t.rows[t.rows.count - 1].append(cell)
                t.cell = nil
                table = t
            case "caption":
                break
            case "table":
                closeTable()
            case "blockquote":
                flush()
                out.append(":::")
                out.append("")
            case "details":
                flush()
                if details.popLast() != nil {
                    out.append(":::")
                    out.append("")
                }
            case "summary":
                if let title = summary, let index = details.last {
                    out[index] = ":::spoiler " + title.trimmingCharacters(in: .whitespaces)
                }
                summary = nil
            case _ where wrapperTags.contains(name):
                let boxed = wrappers.popLast() ?? false
                name == "p" ? blank() : flush()
                if boxed {
                    out.append(":::")
                    out.append("")
                }
            default:
                break
            }
        }

        private func closePre() {
            guard var code = pre else { return }
            pre = nil
            if code.text.hasPrefix("\n") { code.text.removeFirst() }
            while code.text.hasSuffix("\n") { code.text.removeLast() }
            let fence = code.text.contains("```") ? "~~~~" : "```"
            out.append(fence + code.language)
            out += code.text.components(separatedBy: "\n")
            out.append(fence)
            out.append("")
        }

        private func closeTable() {
            guard let t = table else { return }
            table = nil
            let rows = t.rows.filter { !$0.isEmpty }
            if let caption = t.caption?.trimmingCharacters(in: .whitespaces), !caption.isEmpty {
                out.append("**\(caption)**")
                out.append("")
            }
            guard !rows.isEmpty else { return }
            if rows.joined().contains(where: { $0.columnSpan > 1 || $0.rowSpan > 1 }) {
                spanningTable(rows)
            } else {
                markdownTable(rows)
            }
            out.append("")
        }

        /// A Markdown table: the first row is the header, as GitHub needs one.
        private func markdownTable(_ rows: [[Cell]]) {
            let width = rows.map(\.count).max() ?? 0
            func row(_ cells: [Cell]) -> String {
                let texts = cells.map { $0.text.replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\u{2028}", with: " ") }
                return "| " + (texts + Array(repeating: "", count: width - cells.count)).joined(separator: " | ") + " |"
            }
            out.append(row(rows[0]))
            out.append("|" + (0..<width).map { column -> String in
                // A column's alignment is the first one given in it.
                switch rows.lazy.compactMap({ column < $0.count ? $0[column].align : nil }).first {
                case "center": return ":-:"
                case "right": return "--:"
                case "left": return ":--"
                default: return "---"
                }
            }.joined(separator: "|") + "|")
            for cells in rows.dropFirst() { out.append(row(cells)) }
        }

        /// A table with spanning cells: each cell a marked paragraph, placed on the grid as HTML
        /// places it, a cell skipping columns that cells above it still cover.
        private func spanningTable(_ rows: [[Cell]]) {
            var covered = Set<[Int]>()
            var placed: [(cell: Cell, row: Int, column: Int)] = []
            for (r, cells) in rows.enumerated() {
                var c = 0
                for cell in cells {
                    while covered.contains([r, c]) { c += 1 }
                    placed.append((cell, r, c))
                    for dr in 0..<cell.rowSpan { for dc in 0..<cell.columnSpan { covered.insert([r + dr, c + dc]) } }
                    c += cell.columnSpan
                }
            }
            let columns = placed.map { $0.column + $0.cell.columnSpan }.max() ?? 1
            let rowCount = rows.count
            for (cell, r, c) in placed {
                let align = ["center": "c", "right": "r", "left": "l"][cell.align ?? ""] ?? "-"
                // A row span can't reach past the last row.
                let fields = [tableCount, r, c, min(cell.rowSpan, rowCount - r), cell.columnSpan, columns]
                    .map(String.init) + [cell.header ? "1" : "0", align]
                out.append("\(cellMarker)\(fields.joined(separator: ","))\(cellMarkerEnd)\(cell.text.isEmpty ? "\u{200B}" : cell.text)")
                out.append("")
            }
            tableCount += 1
        }

        private func language(_ attributes: [String: String]) -> String? {
            guard let classes = attributes["class"] else { return nil }
            for name in classes.split(separator: " ") {
                for prefix in ["language-", "lang-"] where name.hasPrefix(prefix) {
                    return String(name.dropFirst(prefix.count))
                }
            }
            return nil
        }

        private func textAlign(_ css: String) -> String? {
            for declaration in css.split(separator: ";") {
                let pair = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2, pair[0].lowercased() == "text-align" { return pair[1] }
            }
            return nil
        }
    }
}
