import AppKit

/// Turns Markdown into styled text for the read-only preview.
/// Apple's parser reads the Markdown; this lays out its blocks (which it leaves unstyled
/// and without line breaks between them) and styles headings, lists, quotes, code and tables.
enum MarkdownRenderer {
    static let fileExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    /// Checkboxes link to "menunote-task://<n>", n counting task items from the top of the document.
    static let taskScheme = "menunote-task"

    /// Where each task item's check mark sits in the source (the character between the brackets),
    /// in document order, so a clicked checkbox can be flipped in the text.
    /// Matches the parser's view of task items: list items starting "[ ]" or "[x]", outside fenced code.
    static func taskMarkerRanges(in source: String) -> [NSRange] {
        let ns = source as NSString
        let item = try! NSRegularExpression(pattern: #"^[ \t>]*(?:[-*+]|\d+[.)])[ \t]+\[([ xX])\](?=[ \t])"#)
        var ranges: [NSRange] = []
        var fences = FenceTracker()
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { text, line, _, _ in
            if fences.isFence(text ?? "") {
            } else if !fences.inside, let m = item.firstMatch(in: source, range: line) {
                ranges.append(m.range(at: 1))
            }
        }
        return ranges
    }

    /// `width` is the width the text is laid out in, for sizing table columns. `expandedSpoilers`
    /// numbers the `:::spoiler` blocks shown open, counting from 0 at the top.
    static func render(_ source: String, fontSize: CGFloat, baseURL: URL?, width: CGFloat? = nil,
                       expandedSpoilers: Set<Int> = []) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        let (html, htmlStyles) = HTML.convert(source)
        let (rewritten, notes) = HackMD.rewrite(html)
        guard let parsed = try? AttributedString(markdown: prepare(rewritten), options: options, baseURL: baseURL) else {
            return NSAttributedString(string: source, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor])
        }

        let out = NSMutableAttributedString()
        var lastBlock: PresentationIntent?
        var lastCell: BlockStyle.Cell?
        var lastParagraph: NSParagraphStyle?
        var markedItems = Set<Int>()
        var doneItems = Set<Int>()
        var taskCount = 0
        var quoteBoxes: [Int: NSTextBlock] = [:]
        var tables: [Int: NSTextTable] = [:]

        /// The parser leaves out empty table cells (and rows), which would leave holes in the grid.
        /// Emits empty cells from after the last cell up to `next`, or to the end of the last row.
        func fillCells(until next: BlockStyle.Cell?) {
            guard let last = lastCell, let base = lastParagraph,
                  let table = (base.textBlocks.last as? NSTextTableBlock)?.table else { return }
            let end = next.flatMap { $0.table == last.table ? ($0.row, $0.column) : nil }
            var row = last.row, column = last.column + 1
            while end.map({ (row, column) < $0 }) ?? (row == last.row && column < last.columns) {
                if column >= last.columns {
                    row += 1
                    column = 0
                    continue
                }
                let paragraph = base.mutableCopy() as! NSMutableParagraphStyle
                paragraph.textBlocks = paragraph.textBlocks.dropLast() + [BlockStyle.cellBlock(table, row: row, column: column)]
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: lastParagraph!]))
                out.append(NSAttributedString(string: "\u{200B}", attributes: [.paragraphStyle: paragraph]))
                lastParagraph = paragraph
                column += 1
            }
            if next?.table != last.table { appendTableGap() }
        }

        /// A table keeps no margin below it, so a short empty line (inside any quote) spaces it from what follows.
        func appendTableGap() {
            guard let previous = lastParagraph else { return }
            let gap = NSMutableParagraphStyle()
            gap.textBlocks = previous.textBlocks.dropLast()
            out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: previous]))
            out.append(NSAttributedString(string: "\u{200B}", attributes: [.paragraphStyle: gap,
                                                                           .font: NSFont.systemFont(ofSize: fontSize * 0.4)]))
            lastParagraph = gap
        }
        var htmlTables: [Int: NSTextTable] = [:]
        var htmlCell: (block: NSTextTableBlock, cell: HTML.SpanningCell)?   // the HTML table cell being rendered
        var role = DefinitionRole.none
        var nextLineNumber = 1   // for a code block whose numbering continues the previous one's

        let headings = headings(in: parsed)
        var headingCount = 0
        var anchor: String?                  // the current heading's, for [TOC] links to jump to
        var containers = Set<Int>()          // quotes that are HackMD boxes or spoilers, by identity
        var aligned: [Int: NSTextAlignment] = [:]   // quotes that are centered or right-aligned HTML blocks
        var collapsed: Int?                  // the quote of a closed spoiler, whose content is hidden
        var spoilerCount = 0
        var spoilerLink: URL?                // set while rendering a spoiler's title
        var lastImage: URL?                  // an image's description can span several runs
        var openBox: Int?                    // the outermost box or spoiler being rendered

        for run in parsed.runs {
            var text = String(parsed[run.range].characters)
            let block = run.presentationIntent
            let kinds = block?.components ?? []   // innermost first
            var style = BlockStyle(kinds, fontSize: fontSize, quoteBoxes: &quoteBoxes, tables: &tables)
            let quotes = kinds.filter { if case .blockQuote = $0.kind { return true }; return false }

            if let collapsed, quotes.contains(where: { $0.identity == collapsed }) {
                lastBlock = block
                continue
            }
            if block != lastBlock {
                anchor = nil
                spoilerLink = nil
                if kinds.contains(where: { if case .header = $0.kind { return true }; return false }) {
                    anchor = "heading-\(headingCount)"
                    headingCount += 1
                }
                // The first paragraph of a HackMD box names its kind; it styles the quote and goes.
                if text.first == HackMD.containerMarker, let quote = quotes.first, let box = quoteBoxes[quote.identity] {
                    switch String(text.dropFirst()) {
                    case HTML.quoteBox:
                        break   // <blockquote> looks like any quote
                    case HTML.centerBox, HTML.rightBox:
                        HackMD.styleAlignment(box)
                        containers.insert(quote.identity)
                        aligned[quote.identity] = text.dropFirst() == HTML.centerBox ? .center : .right
                    case let kind:
                        HackMD.styleContainer(box, kind: kind)
                        containers.insert(quote.identity)
                    }
                    lastBlock = block
                    continue
                }
                // A spoiler's first paragraph is its title, which opens and closes it.
                if text.first == HackMD.spoilerMarker, let quote = quotes.first, let box = quoteBoxes[quote.identity] {
                    HackMD.styleSpoiler(box)
                    containers.insert(quote.identity)
                    let open = expandedSpoilers.contains(spoilerCount)
                    if !open { collapsed = quote.identity }
                    spoilerLink = URL(string: "\(HackMD.spoilerScheme)://\(spoilerCount)")
                    spoilerCount += 1
                    text.removeFirst()
                    if text.isEmpty, run.range.upperBound == parsed.endIndex || parsed.runs[run.range.upperBound].presentationIntent != block {
                        text = tr("詳細內容", "Details")
                    }
                    text = (open ? "▼ " : "▶ ") + text
                }
                if text == String(HackMD.tocMarker) {
                    appendContents(headings, to: out, after: &lastParagraph, fontSize: fontSize)
                    lastBlock = block
                    continue
                }
            }
            if quotes.contains(where: { containers.contains($0.identity) }) { style.color = .labelColor }
            // Table cells keep their own alignment.
            if style.cell == nil, let alignment = quotes.lazy.compactMap({ aligned[$0.identity] }).first {
                style.paragraph.alignment = alignment
            }
            // A cell of an HTML table with spanning cells: the marker HTML.convert put first says where.
            var endsHTMLTable = false
            if block != lastBlock {
                let previous = htmlCell
                htmlCell = nil
                if let (cell, length) = HTML.spanningCell(text) {
                    text.removeFirst(length)
                    let table = htmlTables[cell.table] ?? {
                        let table = NSTextTable()
                        table.numberOfColumns = cell.columns
                        table.collapsesBorders = true
                        table.hidesEmptyCells = false
                        htmlTables[cell.table] = table
                        return table
                    }()
                    htmlCell = (BlockStyle.cellBlock(table, row: cell.row, column: cell.column, rowSpan: cell.rowSpan,
                                                     columnSpan: cell.columnSpan, header: cell.header), cell)
                }
                endsHTMLTable = previous != nil && previous?.block.table !== htmlCell?.block.table
            }
            if let (cellBlock, cell) = htmlCell {
                style.paragraph.textBlocks = style.paragraph.textBlocks + [cellBlock]   // inside any quote
                style.paragraph.alignment = cell.alignment
                style.paragraph.paragraphSpacing = 0
                style.paragraph.headIndent = 0
                style.paragraph.firstLineHeadIndent = 0
                if cell.header { style.font = NSFontManager.shared.convert(style.font, toHaveTrait: .boldFontMask) }
            }
            // A box has no margin of its own; space it from what follows, as after a table.
            if block != lastBlock, let box = openBox, !quotes.contains(where: { $0.identity == box }), let previous = lastParagraph {
                let gap = NSMutableParagraphStyle()
                gap.textBlocks = Array(previous.textBlocks.prefix { $0 !== quoteBoxes[box] })
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: previous]))
                out.append(NSAttributedString(string: "\u{200B}", attributes: [.paragraphStyle: gap,
                                                                               .font: NSFont.systemFont(ofSize: fontSize * 0.4)]))
                lastParagraph = gap
                openBox = nil
            }
            if block != lastBlock, openBox == nil {
                openBox = quotes.last { containers.contains($0.identity) }?.identity
            }

            if block != lastBlock {
                // A paragraph that `prepare` marked as a definition-list term or definition.
                role = text.first.flatMap { DefinitionRole(rawValue: $0) } ?? .none
                if role != .none { text.removeFirst() }
            }
            switch role {
            case .term:
                style.font = NSFontManager.shared.convert(style.font, toHaveTrait: .boldFontMask)
                style.paragraph.paragraphSpacing = 2
            case .definition, .lastDefinition:
                style.paragraph.headIndent += 24
                style.paragraph.firstLineHeadIndent += 24
                if role == .definition { style.paragraph.paragraphSpacing = fontSize * 0.25 }
            case .none:
                break
            }
            if style.isRule { text = "\u{200B}" }   // the line is the box's border; the text only holds its place

            if block != lastBlock {
                fillCells(until: style.cell)
                if endsHTMLTable { appendTableGap() }
                lastCell = style.cell
                if out.length > 0 {
                    // The line break ends the previous block, so it takes that block's style; otherwise
                    // the previous block's last line would be drawn as part of this one (one code box
                    // running into the next, say).
                    out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: lastParagraph ?? style.paragraph]))
                }
                lastParagraph = style.paragraph
                if let marker = style.listMarker(kinds, alreadyMarked: &markedItems) {
                    if let done = taskState(text), let item = nearestItem(kinds) {
                        // "[ ] " / "[x] " starts a task item: draw a checkbox in place of the bullet.
                        text.removeFirst(4)
                        if done { doneItems.insert(item) }
                        out.append(checkbox(done: done, index: taskCount, fontSize: fontSize, paragraph: style.paragraph))
                        taskCount += 1
                    } else {
                        out.append(NSAttributedString(string: marker, attributes: [
                            .font: NSFont.systemFont(ofSize: fontSize),
                            .foregroundColor: NSColor.secondaryLabelColor,
                            .paragraphStyle: style.paragraph]))
                    }
                }
            }
            lastBlock = block

            if style.isCode, text.hasSuffix("\n") { text.removeLast() }
            // A line break inside a paragraph, without the spacing that comes after a paragraph.
            if !style.isCode { text = text.replacingOccurrences(of: "\n", with: "\u{2028}") }
            var font = style.font
            var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: style.paragraph,
                                                        .foregroundColor: style.color]

            let inline = run.inlinePresentationIntent ?? []
            if inline.contains(.code) {
                // Keep the size and weight of the text around it (bold in a heading, say); smaller
                // code stands out next to Chinese, which falls back to the same font either way.
                let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
                font = .monospacedSystemFont(ofSize: font.pointSize, weight: bold ? .bold : .regular)
                attrs[inlineCode] = inlineCodeBackground
            }
            if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            // A slant rather than an italic font: Chinese fonts have no italics, so "*斜體*" would stay
            // upright. The system font's italic is itself a slant, so Latin text looks the same.
            if inline.contains(.emphasized) { attrs[.obliqueness] = 0.2 }
            if inline.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let item = nearestItem(kinds), doneItems.contains(item) {
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                // The preview's own link styling is turned off so checkboxes don't look like links.
                attrs[.link] = link
                attrs[.foregroundColor] = NSColor.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if let imageURL = run.imageURL {
                if imageURL == lastImage { continue }   // drawn with the run before
                lastImage = imageURL
                let image = imageOptions(imageURL)
                if case .loaded(let picture) = ImageLoader.shared.image(for: image.source) {
                    // Fit the width the text has, inside any list indent and quote boxes.
                    let room = (width ?? 480) - style.paragraph.headIndent - CGFloat(quotes.count) * 16 - 4
                    let attachment = NSTextAttachment()
                    attachment.image = picture
                    attachment.bounds = CGRect(origin: .zero, size: fitted(picture.size, width: image.width,
                                                                          height: image.height, room: max(40, room)))
                    let piece = NSMutableAttributedString(attachment: attachment)
                    var imageAttrs: [NSAttributedString.Key: Any] = [.paragraphStyle: style.paragraph, .toolTip: text]
                    if let link = image.link ?? run.link { imageAttrs[.link] = link }
                    piece.addAttributes(imageAttrs, range: NSRange(location: 0, length: piece.length))
                    out.append(piece)
                    continue
                }
                // Loading from the web, or couldn't be loaded: its description stands in.
                text = "🖼 " + text
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
                attrs[.toolTip] = image.source.absoluteString
                if let link = image.link { attrs[.link] = link }
            } else {
                lastImage = nil
            }
            if let spoilerLink {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                attrs[.link] = spoilerLink
                attrs[.foregroundColor] = NSColor.labelColor
            }
            if let anchor { attrs[HackMD.anchor] = anchor }
            attrs[.font] = font
            var numbers: [String] = []
            if style.isCode, let numbering = style.lineNumbers {
                let first: Int
                switch numbering {
                case .from(let n): first = n
                case .continued: first = nextLineNumber
                }
                let count = text.components(separatedBy: "\n").count
                nextLineNumber = first + count
                let width = String(first + count - 1).count
                numbers = (first..<first + count).map {
                    String(repeating: " ", count: width - String($0).count) + "\($0)\t"
                }
                // Wrapped lines line up with the code, not under the numbers.
                let column = (String(repeating: "0", count: width) as NSString).size(withAttributes: [.font: font]).width + 12
                style.paragraph.headIndent = column
                style.paragraph.tabStops = [NSTextTab(textAlignment: .left, location: column)]
            }
            let piece = NSMutableAttributedString(string: text, attributes: attrs)
            if inline.contains(.code), piece.length > 0 {
                // Room for the shading to reach past the characters on both sides (see
                // PreviewLayoutManager). Spacing, unlike inserted spaces, doesn't change where lines wrap.
                widen(piece, at: piece.length - 1)
                if let last = out.string.utf16.last, last != 0x0A, last != 0x2028, last != 0x09 {
                    widen(out, at: out.length - 1)
                }
            }
            if style.isCode {
                SyntaxHighlighter.highlight(piece, language: style.language)
                piece.addAttribute(codeBlock, value: true, range: NSRange(location: 0, length: piece.length))
            }
            if !numbers.isEmpty {
                var numberAttrs = attrs
                numberAttrs[.foregroundColor] = NSColor.tertiaryLabelColor
                // Insert from the last line up, so earlier lines' positions stay put.
                var starts = [0]
                (piece.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: piece.length),
                                                              options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
                    starts.append(enclosing.upperBound)
                }
                for (start, number) in zip(starts, numbers).reversed() {
                    piece.insert(NSAttributedString(string: number, attributes: numberAttrs), at: start)
                }
            }
            out.append(piece)
        }
        fillCells(until: nil)
        applyExtensions(in: out, fontSize: fontSize)
        applyHTMLStyles(htmlStyles, in: out, fontSize: fontSize)
        HackMD.applyFootnotes(in: out, fontSize: fontSize)
        HackMD.applyAbbreviations(notes.abbreviations, in: out)
        let tableIDs = Set((Array(tables.values) + Array(htmlTables.values)).map(ObjectIdentifier.init))
        removeOuterBorders(in: out, tables: tableIDs)
        if let width { sizeColumns(in: out, tables: tableIDs, width: width) }
        return out
    }

    /// HackMD's image size (`=200x100`) and a link around the image, which `HackMD.rewrite` carries
    /// in the image URL's fragment because the parser drops both.
    private static func imageOptions(_ url: URL) -> (source: URL, width: CGFloat?, height: CGFloat?, link: URL?) {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let fragment = parts.percentEncodedFragment, fragment.hasPrefix(HackMD.imageOptionPrefix) else {
            return (url, nil, nil, nil)
        }
        var width: CGFloat?, height: CGFloat?, link: URL?
        for option in fragment.split(separator: "&") {
            let pair = option.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case HackMD.imageOptionPrefix + "size":
                let size = pair[1].split(separator: "x", omittingEmptySubsequences: false)
                width = Double(size.first ?? "").map { CGFloat($0) }
                height = size.count > 1 ? Double(size[1]).map { CGFloat($0) } : nil
            case HackMD.imageOptionPrefix + "link":
                link = pair[1].removingPercentEncoding.flatMap(URL.init(string:))
            default:
                break
            }
        }
        parts.percentEncodedFragment = nil
        return (parts.url ?? url, width, height, link)
    }

    /// An image's size: as given (one side keeps the proportions), then shrunk to fit `room`.
    private static func fitted(_ natural: NSSize, width: CGFloat?, height: CGFloat?, room: CGFloat) -> NSSize {
        var size = natural
        switch (width, height) {
        case let (w?, h?): size = NSSize(width: w, height: h)
        case let (w?, nil) where natural.width > 0: size = NSSize(width: w, height: natural.height * w / natural.width)
        case let (nil, h?) where natural.height > 0: size = NSSize(width: natural.width * h / natural.height, height: h)
        default: break
        }
        if size.width > room { size = NSSize(width: room, height: size.height * room / size.width) }
        return size
    }

    /// The document's headings, in order, for [TOC].
    private static func headings(in parsed: AttributedString) -> [(level: Int, title: String)] {
        var headings: [(level: Int, title: String)] = []
        var last: Int?
        for run in parsed.runs {
            guard let heading = run.presentationIntent?.components.first(where: {
                if case .header = $0.kind { return true }; return false
            }), case .header(let level) = heading.kind else { last = nil; continue }
            // Without the markers HackMD and `prepare` put in the text.
            let text = String(parsed[run.range].characters).unicodeScalars
                .filter { !(0xE000...0xE0FF).contains($0.value) && $0 != "\u{200B}" }
            if heading.identity == last {
                headings[headings.count - 1].title += String(String.UnicodeScalarView(text))
            } else {
                headings.append((level, String(String.UnicodeScalarView(text))))
                last = heading.identity
            }
        }
        return headings
    }

    /// The table of contents for [TOC]: a line per heading, indented by level, linking to it.
    private static func appendContents(_ headings: [(level: Int, title: String)], to out: NSMutableAttributedString,
                                       after lastParagraph: inout NSParagraphStyle?, fontSize: CGFloat) {
        let top = headings.map(\.level).min() ?? 1
        for (i, heading) in headings.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = CGFloat(heading.level - top) * 16
            paragraph.headIndent = paragraph.firstLineHeadIndent
            paragraph.paragraphSpacing = i == headings.count - 1 ? fontSize * 0.5 : 2
            if out.length > 0 {
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: lastParagraph ?? paragraph]))
            }
            out.append(NSAttributedString(string: heading.title, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.linkColor,
                .link: URL(string: "\(HackMD.anchorScheme)://heading-\(i)")!,
                .paragraphStyle: paragraph,
            ]))
            lastParagraph = paragraph
        }
    }

    /// The cells of each table in `text`, by table.
    private static func cells(in text: NSAttributedString, tables: Set<ObjectIdentifier>) -> [ObjectIdentifier: [NSTextTableBlock]] {
        var cells: [ObjectIdentifier: [NSTextTableBlock]] = [:]
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let cell = (value as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock,
                  tables.contains(ObjectIdentifier(cell.table)) else { return }
            cells[ObjectIdentifier(cell.table), default: []].append(cell)
        }
        return cells
    }

    /// Tables have lines between cells but none around the outside. The last row is known only
    /// once the whole table is rendered.
    private static func removeOuterBorders(in text: NSAttributedString, tables: Set<ObjectIdentifier>) {
        for blocks in cells(in: text, tables: tables).values {
            guard let lastRow = blocks.map({ $0.startingRow + $0.rowSpan - 1 }).max() else { continue }
            for cell in blocks {
                if cell.startingRow == 0 { cell.setWidth(0, type: .absoluteValueType, for: .border, edge: .minY) }
                if cell.startingRow + cell.rowSpan - 1 == lastRow { cell.setWidth(0, type: .absoluteValueType, for: .border, edge: .maxY) }
                if cell.startingColumn == 0 { cell.setWidth(0, type: .absoluteValueType, for: .border, edge: .minX) }
                if cell.startingColumn + cell.columnSpan == cell.table.numberOfColumns {
                    cell.setWidth(0, type: .absoluteValueType, for: .border, edge: .maxX)
                }
            }
        }
    }

    /// AppKit's table layout splits the width evenly between columns, so a column of short names
    /// takes as much room as one of long text, which then wraps mid-word. Instead columns are sized
    /// the way browsers size them: each as wide as its widest cell if the table fits; otherwise
    /// each at least as wide as its longest word, with the room left shared out by how much more
    /// each column would take.
    private static func sizeColumns(in text: NSAttributedString, tables: Set<ObjectIdentifier>, width: CGFloat) {
        struct Sizing {
            var blocks: [NSTextTableBlock] = []
            var widths: [Int: CGFloat] = [:]
            var minimums: [Int: CGFloat] = [:]
            var spanning: [(block: NSTextTableBlock, width: CGFloat, minimum: CGFloat)] = []
            var available: CGFloat = 0
        }
        var sizing: [ObjectIdentifier: Sizing] = [:]
        let ns = text.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            guard range.length > 0,
                  let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                  let cell = style.textBlocks.last as? NSTextTableBlock,
                  tables.contains(ObjectIdentifier(cell.table)) else { return }
            // The cell's text on one line, without the paragraph's boxes.
            let line = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
            line.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: line.length))
            var entry = sizing[ObjectIdentifier(cell.table), default: Sizing()]
            entry.blocks.append(cell)
            let column = cell.startingColumn
            // Lines inside a cell keep the text container's padding at both ends (5 by default).
            let linePadding: CGFloat = 5 * 2 + 1
            let cellWidth = ceil(line.size().width) + linePadding
            // Words, by the system's word breaking, which also splits Chinese into words.
            var cellMinimum: CGFloat = 0
            (line.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: line.length),
                                                          options: [.byWords, .substringNotRequired]) { _, word, _, _ in
                cellMinimum = max(cellMinimum, ceil(line.attributedSubstring(from: word).size().width) + linePadding)
            }
            if cell.columnSpan > 1 {
                entry.spanning.append((cell, cellWidth, cellMinimum))   // shared out once single columns are known
            } else {
                entry.widths[column] = max(entry.widths[column] ?? 0, cellWidth)
                entry.minimums[column] = max(entry.minimums[column] ?? 0, cellMinimum)
            }
            // What's left after any quotes around the table and the table's own indent.
            entry.available = style.textBlocks.dropLast().reduce(width) { left, box in
                left - box.width(for: .margin, edge: .minX) - box.width(for: .border, edge: .minX)
                    - box.width(for: .padding, edge: .minX)
            } - cell.table.width(for: .margin, edge: .minX)
            sizing[ObjectIdentifier(cell.table)] = entry
        }
        for var entry in sizing.values {
            guard let sample = entry.blocks.first else { continue }
            let columns = sample.table.numberOfColumns
            // Each cell's padding on both sides and its border, between columns a span covers.
            let cellChrome = sample.width(for: .padding, edge: .minX) + sample.width(for: .padding, edge: .maxX)
                + sample.width(for: .border, edge: .minX)
            let chrome = CGFloat(columns) * cellChrome + sample.width(for: .border, edge: .maxX)
            // A spanning cell wider than the columns it covers widens them evenly.
            for (block, width, minimum) in entry.spanning {
                let span = block.startingColumn..<min(columns, block.startingColumn + block.columnSpan)
                let between = CGFloat(span.count - 1) * cellChrome
                for (key, needed) in [(\Sizing.widths, width), (\Sizing.minimums, minimum)] {
                    let have = span.reduce(between) { $0 + (entry[keyPath: key][$1] ?? 0) }
                    guard needed > have else { continue }
                    for c in span { entry[keyPath: key][c, default: 0] += (needed - have) / CGFloat(span.count) }
                }
            }
            let widest = (0..<columns).map { entry.widths[$0] ?? 0 }
            let narrowest = (0..<columns).map { min(entry.minimums[$0] ?? 0, widest[$0]) }
            let room = max(entry.available - chrome, 0)
            let total = widest.reduce(0, +), least = narrowest.reduce(0, +)
            let widths: [CGFloat]
            if total <= room {
                widths = widest
            } else if least >= room {
                // Even the longest words don't fit; shrink them all alike.
                widths = narrowest.map { least > 0 ? $0 * room / least : 0 }
            } else {
                let share = (room - least) / (total - least)
                widths = (0..<columns).map { narrowest[$0] + (widest[$0] - narrowest[$0]) * share }
            }
            for block in entry.blocks {
                let span = block.startingColumn..<min(columns, block.startingColumn + block.columnSpan)
                let width = span.reduce(CGFloat(span.count - 1) * cellChrome) { $0 + widths[$1] }
                block.setValue(width, type: .absoluteValueType, for: .width)
            }
        }
    }

    /// Marks the text of code blocks, which later passes leave as typed.
    static let codeBlock = NSAttributedString.Key("MenuNoteCodeBlock")
    /// Marks `code` in a sentence; the value is the color PreviewLayoutManager shades it with.
    static let inlineCode = NSAttributedString.Key("MenuNoteInlineCode")
    /// How far the shading reaches past inline code on each side.
    static let inlineCodePadding: CGFloat = 3

    /// Adds room after one character: the shading's padding plus the same again as a gap.
    private static func widen(_ text: NSMutableAttributedString, at index: Int) {
        let kern = text.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat ?? 0
        text.addAttribute(.kern, value: kern + inlineCodePadding * 2, range: NSRange(location: index, length: 1))
    }

    /// GitHub's shading for `code` in a sentence, a little stronger. A few characters need more
    /// contrast than a whole code block; the system's quaternary label color nearly vanishes
    /// against a dark background.
    private static let inlineCodeBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 110 / 255, green: 118 / 255, blue: 129 / 255, alpha: 0.5)
            : NSColor(srgbRed: 175 / 255, green: 184 / 255, blue: 193 / 255, alpha: 0.4)
    }

    // MARK: - HackMD's inline extensions

    /// Styles Apple's parser doesn't know: ==highlight==, ++underline++, ^superscript^ and
    /// ~subscript~ (where a single tilde would otherwise strike through, as on GitHub).
    /// `prepare` wraps them in private-use characters, which pass through the parser as text;
    /// `applyExtensions` then styles what's between and removes them.
    private enum Extension: CaseIterable {
        case highlight, underline, superscript, `subscript`

        var pattern: String {
            switch self {
            case .highlight: return #"==(?=[^\s=])(.+?)(?<=[^\s=])=="#
            case .underline: return #"\+\+(?=[^\s+])(.+?)(?<=[^\s+])\+\+"#
            case .superscript: return #"\^([^\^\s]+)\^"#
            case .subscript: return #"(?<!~)~([^~\s]+)~(?!~)"#
            }
        }
        var open: Character {
            switch self {
            case .highlight: return "\u{E010}"
            case .underline: return "\u{E012}"
            case .superscript: return "\u{E014}"
            case .subscript: return "\u{E016}"
            }
        }
        var close: Character { Character(Unicode.Scalar(open.unicodeScalars.first!.value + 1)!) }
        var regex: NSRegularExpression { Self.regexes[self]! }
        private static let regexes = Dictionary(uniqueKeysWithValues: allCases.map {
            ($0, try! NSRegularExpression(pattern: $0.pattern))
        })
    }

    /// Wraps the extensions in one line in their markers, leaving inline code alone.
    private static func markingExtensions(_ line: String) -> String {
        HackMD.outsideCode(line) { text in
            Extension.allCases.reduce(text) { text, ext in
                ext.regex.stringByReplacingMatches(
                    in: text, range: NSRange(location: 0, length: (text as NSString).length),
                    withTemplate: "\(ext.open)$1\(ext.close)")
            }
        }
    }

    /// Styles the text between HTML's markers (see HTML.convert) and removes them.
    private static func applyHTMLStyles(_ styles: [HTML.Style], in text: NSMutableAttributedString, fontSize: CGFloat) {
        guard !styles.isEmpty else { return }
        let ns = text.string as NSString
        var open: [(index: Int, start: Int)] = []   // style number, and where its content starts
        var markers: [NSRange] = []
        var ranges: [(style: HTML.Style, range: NSRange)] = []
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if c == HTML.open.utf16.first!, let end = (i + 1..<ns.length).first(where: { ns.character(at: $0) == HTML.openEnd.utf16.first! }),
               let index = Int(ns.substring(with: NSRange(location: i + 1, length: end - i - 1))) {
                markers.append(NSRange(location: i, length: end - i + 1))
                open.append((index, end + 1))
                i = end + 1
                continue
            }
            if c == HTML.close.utf16.first! {
                markers.append(NSRange(location: i, length: 1))
                if let last = open.popLast(), styles.indices.contains(last.index) {
                    ranges.append((styles[last.index], NSRange(location: last.start, length: i - last.start)))
                }
            }
            i += 1
        }
        // Outer elements first, so an inner one's look wins where they differ.
        for (style, range) in ranges.reversed() where range.length > 0 {
            apply(style, to: text, range, fontSize: fontSize)
        }
        for marker in markers.reversed() { text.deleteCharacters(in: marker) }
    }

    private static func apply(_ style: HTML.Style, to text: NSMutableAttributedString, _ range: NSRange, fontSize: CGFloat) {
        text.enumerateAttribute(.font, in: range) { value, run, _ in
            var font = value as? NSFont ?? .systemFont(ofSize: fontSize)
            if style.code {
                let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
                font = .monospacedSystemFont(ofSize: font.pointSize, weight: bold ? .bold : .regular)
            }
            if style.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if let scale = style.scale { font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font }
            if style.raised || style.lowered {
                font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 0.75) ?? font
            }
            text.addAttribute(.font, value: font, range: run)
        }
        var attrs: [NSAttributedString.Key: Any] = [:]
        if style.italic { attrs[.obliqueness] = 0.2 }
        if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.dotted {
            attrs[.underlineStyle] = NSUnderlineStyle.single.union(.patternDot).rawValue
            attrs[.underlineColor] = NSColor.secondaryLabelColor
        }
        if style.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if style.raised { attrs[.baselineOffset] = fontSize * 0.35 }
        if style.lowered { attrs[.baselineOffset] = -fontSize * 0.15 }
        if let color = style.color { attrs[.foregroundColor] = color }
        if let background = style.background {
            attrs[.backgroundColor] = background
            // A solid background given without a text color: dark mode's white text would vanish
            // on yellow, say, so pick black or white by how light the background is.
            if style.color == nil, let rgb = background.usingColorSpace(.sRGB), rgb.alphaComponent > 0.9 {
                let lightness = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
                attrs[.foregroundColor] = lightness > 0.6 ? NSColor.black : NSColor.white
            }
        }
        if let tooltip = style.tooltip { attrs[.toolTip] = tooltip }
        if let link = style.link {
            attrs[.link] = link
            attrs[.foregroundColor] = style.color ?? NSColor.linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.code {
            attrs[inlineCode] = inlineCodeBackground
            widen(text, at: NSMaxRange(range) - 1)
            if range.location > 0 { widen(text, at: range.location - 1) }
        }
        text.addAttributes(attrs, range: range)
    }

    /// A marker-yellow that keeps text readable in both appearances.
    private static let highlightColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.8, green: 0.65, blue: 0.1, alpha: 0.45)
            : NSColor(srgbRed: 1, green: 0.9, blue: 0.3, alpha: 0.6)
    }

    private static func applyExtensions(in text: NSMutableAttributedString, fontSize: CGFloat) {
        let ns = text.string as NSString
        var opened: [Character: [Int]] = [:]
        var markers: [Int] = []
        for i in 0..<ns.length {
            guard let scalar = Unicode.Scalar(ns.character(at: i)) else { continue }
            let c = Character(scalar)
            if let ext = Extension.allCases.first(where: { $0.open == c }) {
                opened[ext.open, default: []].append(i)
                markers.append(i)
            } else if let ext = Extension.allCases.first(where: { $0.close == c }) {
                markers.append(i)
                guard let start = opened[ext.open]?.popLast() else { continue }
                style(text, NSRange(location: start + 1, length: i - start - 1), as: ext, fontSize: fontSize)
            }
        }
        for i in markers.reversed() { text.deleteCharacters(in: NSRange(location: i, length: 1)) }
    }

    private static func style(_ text: NSMutableAttributedString, _ range: NSRange, as ext: Extension, fontSize: CGFloat) {
        switch ext {
        case .highlight:
            text.addAttribute(.backgroundColor, value: highlightColor, range: range)
        case .underline:
            text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .superscript, .subscript:
            text.enumerateAttribute(.font, in: range) { value, run, _ in
                let font = value as? NSFont ?? .systemFont(ofSize: fontSize)
                text.addAttribute(.font, value: NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 0.75) ?? font, range: run)
            }
            text.addAttribute(.baselineOffset, value: ext == .superscript ? fontSize * 0.35 : -fontSize * 0.15, range: range)
        }
    }

    /// Marks the first character of a definition-list term or definition, so `render` can style it.
    private enum DefinitionRole: Character {
        case none = "\0"
        case term = "\u{E001}"
        case definition = "\u{E000}"
        /// The last definition of a term, spaced from what follows like any paragraph.
        case lastDefinition = "\u{E002}"
    }

    /// Rewrites the source before parsing, outside fenced code:
    /// - Markdown joins consecutive lines into one paragraph; in a note, a new line should look like one.
    ///   Ending each line with two spaces makes it a hard line break.
    /// - Apple's parser doesn't know definition lists ("Term" then ": Definition" or "~ Definition"
    ///   on the next lines). Each term and definition becomes its own paragraph, marked for `render`.
    /// - Apple's parser drops empty list items ("1." alone on a line), which should still show their
    ///   marker. An invisible character gives them content, and a blank line after keeps the next
    ///   line from joining the item as before. Like a list item with no text, it can't interrupt a
    ///   paragraph; there a lone "-" underlines a heading instead.
    private static func prepare(_ source: String) -> String {
        let lead = try! NSRegularExpression(pattern: #"^[ \t>]*"#)
        let definition = try! NSRegularExpression(pattern: #"^[:~][ \t]+(?=\S)"#)
        let emptyItem = try! NSRegularExpression(pattern: #"^[ \t>]*(?:[-*+]|\d{1,9}[.)])[ \t]*$"#)
        /// Lines after which a new block can start without a blank line: headings, rules and list items.
        let blockEnd = try! NSRegularExpression(pattern: #"^[ \t>]*(?:#{1,6}(?:[ \t]|$)|(?:[-*_][ \t]*){3,}$|=+[ \t]*$|(?:[-*+]|\d{1,9}[.)])(?:[ \t]|$))"#)
        func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
            regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }
        let lines = source.components(separatedBy: "\n")

        /// The quote markers and indent in front of a line, and the rest of it.
        func split(_ line: String) -> (prefix: String, rest: String) {
            let ns = line as NSString
            let end = lead.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))?.range.length ?? 0
            return (ns.substring(to: end), ns.substring(from: end))
        }
        /// The definition's text without its ":" or "~", if the line is one.
        func definitionText(_ line: String) -> String? {
            let rest = split(line).rest as NSString
            guard let m = definition.firstMatch(in: rest as String, range: NSRange(location: 0, length: rest.length)) else { return nil }
            return rest.substring(from: m.range.length)
        }
        func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

        var out: [String] = []
        var fences = FenceTracker()
        var afterTermOrDefinition = false
        for (i, line) in lines.enumerated() {
            if fences.isFence(line) {
                out.append(line)
                afterTermOrDefinition = false
                continue
            }
            if fences.inside || isBlank(line) {
                out.append(line)
                afterTermOrDefinition = false
                continue
            }
            let line = markingExtensions(line)
            if matches(emptyItem, line), i == 0 || isBlank(lines[i - 1]) || matches(blockEnd, lines[i - 1]) {
                out.append(line + " \u{200B}")
                out.append(split(line).prefix.trimmingCharacters(in: .whitespaces))
                afterTermOrDefinition = false
                continue
            }
            let (prefix, rest) = split(line)
            // A blank line (keeping any quote markers) between them makes term and definition separate paragraphs.
            let separator = prefix.trimmingCharacters(in: .whitespaces)
            if afterTermOrDefinition, let text = definitionText(line) {
                out.append(separator)
                let last = i + 1 == lines.count || definitionText(lines[i + 1]) == nil
                let role = last ? DefinitionRole.lastDefinition : .definition
                out.append(prefix + String(role.rawValue) + text + "  ")
            } else if i + 1 < lines.count, definitionText(lines[i + 1]) != nil, definitionText(line) == nil {
                out.append(prefix + String(DefinitionRole.term.rawValue) + rest + "  ")
                afterTermOrDefinition = true
            } else {
                // A line already ending in a backslash is a hard break as typed; spaces after would undo it.
                out.append(line.hasSuffix("\\") ? line : line + "  ")
                afterTermOrDefinition = false
            }
        }
        return out.joined(separator: "\n")
    }

    /// true for "[x] …", false for "[ ] …", nil if the text isn't a task item.
    private static func taskState(_ text: String) -> Bool? {
        switch text.prefix(4) {
        case "[ ] ", "[ ]\t": return false
        case "[x] ", "[X] ", "[x]\t", "[X]\t": return true
        default: return nil
        }
    }

    private static func nearestItem(_ kinds: [PresentationIntent.IntentType]) -> Int? {
        kinds.first { if case .listItem = $0.kind { return true }; return false }?.identity
    }

    private static func checkbox(done: Bool, index: Int, fontSize: CGFloat, paragraph: NSParagraphStyle) -> NSAttributedString {
        let config = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
            // A checked box is a white check on an accent-colored square.
            .applying(.init(paletteColors: done ? [.white, .controlAccentColor] : [.secondaryLabelColor]))
        let image = NSImage(systemSymbolName: done ? "checkmark.square.fill" : "square", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let attachment = NSTextAttachment()
        attachment.image = image
        if let size = image?.size {
            // Sit the box on the text's baseline like a capital letter would.
            attachment.bounds = NSRect(x: 0, y: (NSFont.systemFont(ofSize: fontSize).capHeight - size.height) / 2,
                                       width: size.width, height: size.height)
        }
        let link = URL(string: "\(taskScheme)://\(index)")!
        let box = NSMutableAttributedString(attachment: attachment)
        box.append(NSAttributedString(string: "\t"))
        box.addAttributes([.link: link, .paragraphStyle: paragraph, .font: NSFont.systemFont(ofSize: fontSize),
                           .toolTip: done ? tr("標為未完成", "Mark as not done") : tr("標為完成", "Mark as done")],
                          range: NSRange(location: 0, length: box.length))
        return box
    }

    /// How one block (paragraph, heading, list item, quote, code block or table cell) looks.
    private struct BlockStyle {
        var font: NSFont
        var color = NSColor.labelColor
        var isCode = false
        /// A thematic break ("---"), drawn as a line across the full width.
        var isRule = false
        /// The language named after a code fence's backticks, e.g. "python".
        var language: String?
        /// HackMD's "```js=" shows line numbers: "=" from 1, "=101" from 101, "=+" continuing
        /// the previous numbered block.
        var lineNumbers: LineNumbers?
        enum LineNumbers {
            case from(Int)
            case continued
        }
        private var codeBox: NSTextBlock?
        let paragraph = NSMutableParagraphStyle()
        private let listDepth: Int

        /// Where a table cell sits. Rows count the header as 0.
        struct Cell {
            let table: Int, row: Int, column: Int, columns: Int
        }
        var cell: Cell?

        /// One cell of a table's grid; header cells are shaded, with a heavier line below the header row.
        /// `header` defaults to the first row, as in Markdown tables; HTML says which cells are.
        static func cellBlock(_ table: NSTextTable, row: Int, column: Int, rowSpan: Int = 1, columnSpan: Int = 1,
                              header: Bool? = nil) -> NSTextTableBlock {
            let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: rowSpan,
                                         startingColumn: column, columnSpan: columnSpan)
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setBorderColor(.tertiaryLabelColor)
            block.setWidth(4, type: .absoluteValueType, for: .padding)
            block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
            if header ?? (row == 0) { block.backgroundColor = .quaternaryLabelColor }
            if header ?? true, row == 0 {
                // A heavier, darker line under the header.
                block.setWidth(2, type: .absoluteValueType, for: .border, edge: .maxY)
                block.setBorderColor(.secondaryLabelColor, for: .maxY)
            }
            return block
        }

        /// `quoteBoxes` and `tables` hold the box drawn for each quote and the grid for each table,
        /// shared by all of their paragraphs.
        init(_ kinds: [PresentationIntent.IntentType], fontSize: CGFloat,
             quoteBoxes: inout [Int: NSTextBlock], tables: inout [Int: NSTextTable]) {
            font = .systemFont(ofSize: fontSize)
            var quotes: [NSTextBlock] = [], lists = 0
            paragraph.paragraphSpacing = fontSize * 0.5
            for intent in kinds {
                switch intent.kind {
                case .header(let level):
                    let scale: [CGFloat] = [1.6, 1.4, 1.2, 1.1, 1.0, 1.0]
                    font = .boldSystemFont(ofSize: fontSize * scale[min(max(level, 1), 6) - 1])
                    paragraph.paragraphSpacingBefore = fontSize * 0.6
                    if level <= 2 {
                        // A line 10pt under first- and second-level headings, as on GitHub. The space
                        // after the heading moves below the line, so the line stays close to the text;
                        // a box equal only to itself keeps two headings in a row from sharing one.
                        let underline = CodeBox()
                        underline.setValue(100, type: .percentageValueType, for: .width)
                        underline.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxY)
                        underline.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                        underline.setBorderColor(.tertiaryLabelColor, for: .maxY)
                        underline.setWidth(paragraph.paragraphSpacing, type: .absoluteValueType, for: .margin, edge: .maxY)
                        paragraph.paragraphSpacing = 0
                        paragraph.textBlocks = [underline]
                    }
                case .codeBlock(let languageHint):
                    if let hint = languageHint, let equals = hint.firstIndex(of: "=") {
                        language = String(hint[..<equals])
                        let rest = hint[hint.index(after: equals)...].filter { $0 != "!" }   // "!" wraps lines; ours always do
                        lineNumbers = rest == "+" ? .continued : .from(Int(rest) ?? 1)
                    } else {
                        language = languageHint?.replacingOccurrences(of: "!", with: "")
                    }
                    font = .monospacedSystemFont(ofSize: fontSize * 0.92, weight: .regular)
                    isCode = true
                    paragraph.paragraphSpacing = 2   // its lines are paragraphs too; keep them tight
                    // One shaded box across the full width; a background color on the text
                    // would shade only the characters, leaving a ragged edge and bare blank lines.
                    let box = CodeBox()
                    box.setValue(100, type: .percentageValueType, for: .width)
                    box.backgroundColor = .quaternaryLabelColor
                    box.setWidth(8, type: .absoluteValueType, for: .padding)
                    paragraph.textBlocks = [box]
                    codeBox = box
                case .blockQuote:
                    color = .secondaryLabelColor
                case .orderedList, .unorderedList:
                    lists += 1
                case .tableHeaderRow:
                    font = .boldSystemFont(ofSize: fontSize)
                case .thematicBreak:
                    isRule = true
                    font = .systemFont(ofSize: fontSize * 0.4)
                    let line = NSTextBlock()
                    line.setValue(100, type: .percentageValueType, for: .width)
                    line.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                    line.setBorderColor(.tertiaryLabelColor, for: .maxY)
                    line.setWidth(fontSize * 0.4, type: .absoluteValueType, for: .margin, edge: .minY)
                    line.setWidth(fontSize * 0.8, type: .absoluteValueType, for: .margin, edge: .maxY)
                    paragraph.textBlocks = [line]
                default:
                    break
                }
            }
            listDepth = lists
            // A bar down the left of each quote, nested quotes inside their parent's bar. Going
            // outermost first, the lists entered since the last quote indent the next quote's box;
            // the lists inside the innermost quote indent the text.
            var listsInside = 0
            for intent in kinds.reversed() {
                switch intent.kind {
                case .orderedList, .unorderedList:
                    listsInside += 1
                case .blockQuote:
                    let indent = CGFloat(listsInside) * 22
                    quotes.append(quoteBoxes[intent.identity] ?? {
                        // A one-cell table rather than a plain box: a table inside the quote expects
                        // every box around it to be a table cell, and crashes drawing otherwise.
                        let frame = NSTextTable()
                        frame.numberOfColumns = 1
                        frame.setValue(100, type: .percentageValueType, for: .width)
                        frame.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
                        let box = NSTextTableBlock(table: frame, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
                        box.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                        box.setBorderColor(.tertiaryLabelColor, for: .minX)
                        box.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                        box.setWidth(2, type: .absoluteValueType, for: .padding, edge: .minY)
                        box.setWidth(2, type: .absoluteValueType, for: .padding, edge: .maxY)
                        quoteBoxes[intent.identity] = box
                        return box
                    }())
                    listsInside = 0
                default:
                    break
                }
            }
            let indent = CGFloat(listsInside) * 22
            if let cellIntent = kinds.first(where: { if case .tableCell = $0.kind { return true }; return false }),
               case .tableCell(let column) = cellIntent.kind,
               let tableIntent = kinds.first(where: { if case .table = $0.kind { return true }; return false }),
               case .table(let columns) = tableIntent.kind {
                let row = kinds.lazy.compactMap { intent -> Int? in
                    if case .tableRow(let index) = intent.kind { return index }
                    if case .tableHeaderRow = intent.kind { return 0 }
                    return nil
                }.first ?? 0
                let table = tables[tableIntent.identity] ?? {
                    let table = NSTextTable()
                    table.numberOfColumns = columns.count
                    table.collapsesBorders = true
                    table.hidesEmptyCells = false
                    table.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
                    tables[tableIntent.identity] = table
                    return table
                }()
                cell = Cell(table: tableIntent.identity, row: row, column: column, columns: columns.count)
                switch columns.indices.contains(column) ? columns[column].alignment : .left {
                case .right: paragraph.alignment = .right
                case .center: paragraph.alignment = .center
                default: paragraph.alignment = .natural
                }
                paragraph.paragraphSpacing = 0
                paragraph.textBlocks = quotes + [Self.cellBlock(table, row: row, column: column)]
                return
            }
            if let codeBox {
                // An unshaded outer box spaces the shaded one from its neighbors and, inside a list
                // or quote, indents it. A margin on the shaded box would be shaded too, and an
                // indent on the text would move only the text.
                let outer = CodeBox()
                outer.setValue(100, type: .percentageValueType, for: .width)
                outer.setWidth(indent, type: .absoluteValueType, for: .padding, edge: .minX)
                outer.setWidth(fontSize * 0.3, type: .absoluteValueType, for: .padding, edge: .minY)
                outer.setWidth(fontSize * 0.5, type: .absoluteValueType, for: .padding, edge: .maxY)
                paragraph.textBlocks = quotes + [outer, codeBox]
                return
            }
            paragraph.textBlocks = quotes + paragraph.textBlocks   // a rule's line goes inside any quote
            paragraph.headIndent = indent
            paragraph.firstLineHeadIndent = listsInside > 0 ? indent - 22 : indent
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        }

        /// "•", "◦", "▪" by depth, or "3." for ordered lists, followed by a tab to the text's indent.
        /// Only the first block of each list item gets one.
        func listMarker(_ kinds: [PresentationIntent.IntentType], alreadyMarked: inout Set<Int>) -> String? {
            guard let itemIndex = kinds.firstIndex(where: { if case .listItem = $0.kind { return true }; return false }),
                  alreadyMarked.insert(kinds[itemIndex].identity).inserted,
                  case .listItem(let ordinal) = kinds[itemIndex].kind else { return nil }
            let list = kinds[(itemIndex + 1)...].first {
                if case .orderedList = $0.kind { return true }
                if case .unorderedList = $0.kind { return true }
                return false
            }
            if case .orderedList? = list?.kind { return "\(ordinal).\t" }
            return ["•", "◦", "▪"][(listDepth - 1) % 3] + "\t"
        }
    }
}

/// The boxes around one code block. Boxes that look alike compare equal by default, and
/// AppKit draws neighboring paragraphs with equal boxes as one, which would merge two code
/// blocks in a row; a box equal only to itself keeps them apart.
private final class CodeBox: NSTextBlock {
    override func isEqual(_ object: Any?) -> Bool { self === object as AnyObject }
    override var hash: Int { ObjectIdentifier(self).hashValue }
}

/// Draws the preview's inline code shading: a rounded box a little wider than the characters,
/// which a plain background color can't do. The renderer leaves room for it with extra spacing
/// before the code and after its last character.
final class PreviewLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let padding = MarkdownRenderer.inlineCodePadding
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(MarkdownRenderer.inlineCode, in: characters) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0, let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { return }
            color.setFill()
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                // Reach `padding` before the first character; the last one's spacing already
                // holds `padding` and a gap after it, so the width stays the same.
                let box = rect.offsetBy(dx: origin.x - padding, dy: origin.y).insetBy(dx: 0, dy: 1)
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            }
        }
    }
}

/// Follows fenced code blocks line by line as CommonMark does: a block closes only at a fence of
/// the same character, at least as long, with nothing after it. So "````" can show a "```" block
/// as code, and a line with a language name after the backticks always opens one.
struct FenceTracker {
    private(set) var inside = false
    private var character: Character = "`"
    private var length = 0
    private static let pattern = try! NSRegularExpression(pattern: #"^[ \t>]*(`{3,}|~{3,})(.*)$"#)

    /// Takes the next line. True if it opens or closes a block, so it's a fence rather than content.
    mutating func isFence(_ line: String) -> Bool {
        let ns = line as NSString
        guard let m = Self.pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return false }
        let run = ns.substring(with: m.range(at: 1))
        let rest = ns.substring(with: m.range(at: 2))
        if inside {
            guard run.first == character, run.count >= length,
                  rest.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            inside = false
            return true
        }
        if run.first == "`", rest.contains("`") { return false }   // inline code, not a fence
        inside = true
        character = run.first!
        length = run.count
        return true
    }
}
