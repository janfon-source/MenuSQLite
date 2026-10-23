import AppKit

/// A window for importing a CSV file into a table: which CSV field fills each of the table's
/// columns, whether the first line names the fields, and whether to add to the table's rows or
/// replace them, with the file's first rows shown below.
final class ImportWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let panel: NSPanel
    private let text: String
    private let fileName: String
    private var separator: Character
    private var rows: [[String]] = []
    private var plan: CSVImport

    private let headerCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let separatorPopUp = NSPopUpButton()
    private let emptyCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let modePopUp = NSPopUpButton()
    private let mapping = NSTableView()
    private let preview = NSTableView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private var importButton: NSButton!

    /// What to import, once the window closes with Import.
    private(set) var result: CSVImport?

    init(text: String, fileName: String, table: String, columns: [Column]) {
        self.text = text
        self.fileName = fileName
        separator = CSV.guessSeparator(text)
        plan = CSVImport(table: table, columns: columns, sources: [], rows: [])
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = tr("匯入 CSV 到「\(table)」", "Import CSV into “\(table)”")
        panel.minSize = NSSize(width: 520, height: 480)
        build()
        reparse()
    }

    var window: NSWindow { panel }

    /// Shows the window until it's closed; true if Import was clicked.
    func run() -> Bool {
        panel.center()
        return NSApp.runModal(for: panel) == .OK
    }

    // MARK: Layout

    private func build() {
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor

        headerCheck.title = tr("第一列是欄位名稱", "First line names the fields")
        headerCheck.target = self
        headerCheck.action = #selector(optionsChanged(_:))
        let separatorLabel = NSTextField(labelWithString: tr("分隔符號", "Separator"))
        separatorPopUp.addItems(withTitles: [tr("逗號 ,", "Comma ,"), "Tab", tr("分號 ;", "Semicolon ;")])
        separatorPopUp.selectItem(at: CSV.separators.firstIndex(of: separator) ?? 0)
        separatorPopUp.target = self
        separatorPopUp.action = #selector(separatorChanged(_:))
        let fileRow = NSStackView(views: [headerCheck, NSView(), separatorLabel, separatorPopUp])

        let mappingLabel = NSTextField(labelWithString: tr("每個欄位要填入的 CSV 欄", "The CSV field for each column"))
        mappingLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        for (id, title, width) in [("column", tr("資料表欄位", "Column"), CGFloat(200)), ("source", tr("CSV 欄", "CSV Field"), 260)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            mapping.addTableColumn(column)
        }
        mapping.dataSource = self
        mapping.delegate = self
        mapping.rowHeight = 26
        mapping.usesAlternatingRowBackgroundColors = true
        mapping.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let mappingScroll = NSScrollView()
        mappingScroll.documentView = mapping
        mappingScroll.hasVerticalScroller = true
        mappingScroll.borderType = .bezelBorder

        emptyCheck.title = tr("空白欄位存成 NULL", "Store empty fields as NULL")
        emptyCheck.state = .on
        emptyCheck.target = self
        emptyCheck.action = #selector(optionsChanged(_:))
        modePopUp.addItems(withTitles: [tr("加在現有資料後面", "Add to the table’s rows"),
                                        tr("先清空資料表再匯入", "Replace the table’s rows")])
        modePopUp.target = self
        modePopUp.action = #selector(optionsChanged(_:))
        let optionsRow = NSStackView(views: [emptyCheck, NSView(), modePopUp])

        let previewLabel = NSTextField(labelWithString: tr("檔案內容（前 20 列）", "The file (first 20 lines)"))
        previewLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        preview.dataSource = self
        preview.delegate = self
        preview.rowHeight = 20
        preview.usesAlternatingRowBackgroundColors = true
        preview.columnAutoresizingStyle = .noColumnAutoresizing
        preview.gridStyleMask = [.solidVerticalGridLineMask]
        let previewScroll = NSScrollView()
        previewScroll.documentView = preview
        previewScroll.hasVerticalScroller = true
        previewScroll.hasHorizontalScroller = true
        previewScroll.borderType = .bezelBorder

        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        importButton = NSButton(title: tr("匯入", "Import"), target: self, action: #selector(importClicked(_:)))
        importButton.keyEquivalent = "\r"
        let cancel = NSButton(title: tr("取消", "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [NSView(), cancel, importButton])

        let stack = NSStackView(views: [summary, fileRow, mappingLabel, mappingScroll, optionsRow,
                                        previewLabel, previewScroll, message, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        for view in [summary, fileRow, mappingScroll, optionsRow, previewScroll, message, actions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        stack.setCustomSpacing(14, after: fileRow)
        stack.setCustomSpacing(14, after: optionsRow)
        mappingScroll.setContentHuggingPriority(.init(1), for: .vertical)
        previewScroll.setContentHuggingPriority(.init(1), for: .vertical)
        mappingScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
        ])
    }

    // MARK: The file

    private var fieldCount: Int { rows.map(\.count).max() ?? 0 }
    private var hasHeader: Bool { headerCheck.state == .on }
    private var header: [String]? { hasHeader ? rows.first : nil }
    private var dataRows: [[String]] { hasHeader ? Array(rows.dropFirst()) : rows }

    /// Reads the file again with the separator chosen, and guesses whether it has a header: it
    /// does if a field of the first line has one of the column names.
    private func reparse() {
        rows = CSV.parse(text, separator: separator)
        let names = Set(plan.columns.map { $0.name.lowercased() })
        let first = rows.first?.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
        headerCheck.state = first.contains(where: names.contains) ? .on : .off
        rematch()
    }

    private func rematch() {
        plan.sources = CSVImport.match(plan.columns, header: header, fieldCount: fieldCount)
        rebuildPreview()
        mapping.reloadData()
        update()
    }

    /// The preview's columns: one per CSV field, named as the header names them.
    private func rebuildPreview() {
        for column in preview.tableColumns { preview.removeTableColumn(column) }
        for i in 0..<fieldCount {
            let column = NSTableColumn(identifier: .init(String(i)))
            column.title = fieldName(i)
            column.width = 110
            preview.addTableColumn(column)
        }
        preview.reloadData()
    }

    private func fieldName(_ i: Int) -> String {
        if let name = header?[safe: i], !name.isEmpty { return name }
        return tr("第 \(i + 1) 欄", "Field \(i + 1)")
    }

    private func update() {
        plan.rows = dataRows
        plan.emptyIsNull = emptyCheck.state == .on
        plan.replace = modePopUp.indexOfSelectedItem == 1
        summary.stringValue = tr("「\(fileName)」：\(plan.rows.count) 列資料，每列 \(fieldCount) 欄。",
                                 "“\(fileName)”: \(plan.rows.count) row\(plan.rows.count == 1 ? "" : "s") of \(fieldCount) field\(fieldCount == 1 ? "" : "s").")
        // Columns that must have a value but get none from the file and have no default.
        let unfilled = plan.columns.indices.filter { i in
            let column = plan.columns[i]
            return plan.sources[i] == nil && column.notNull && column.defaultValue == nil && column.primaryKey == 0
        }.map { plan.columns[$0].name }
        if !plan.hasColumns {
            show(tr("至少要選一個欄位匯入。", "Choose at least one column to import."), error: true)
        } else if plan.rows.isEmpty {
            show(tr("檔案裡沒有資料列。", "The file has no rows."), error: true)
        } else if !unfilled.isEmpty {
            show(tr("「\(unfilled.joined(separator: "、"))」不允許空值又沒有預設值，沒有對應的 CSV 欄會無法匯入。",
                    "\(unfilled.joined(separator: ", ")) can’t be NULL and has no default; without a CSV field the import will fail."), error: false)
        } else if plan.replace {
            show(tr("匯入前會先刪除資料表裡現有的所有資料列。", "Every row already in the table is deleted first."), error: false)
        } else {
            show("", error: false)
        }
    }

    private func show(_ text: String, error: Bool) {
        message.stringValue = text
        message.textColor = error ? .systemRed : .systemOrange
        message.isHidden = text.isEmpty
        importButton.isEnabled = plan.hasColumns && !plan.rows.isEmpty
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === mapping ? plan.columns.count : min(rows.count, 20)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        if tableView === preview {
            let field = NSTextField(labelWithString: rows[row][safe: Int(id) ?? 0] ?? "")
            field.lineBreakMode = .byTruncatingTail
            field.font = .monospacedSystemFont(ofSize: 11, weight: hasHeader && row == 0 ? .bold : .regular)
            return field
        }
        let column = plan.columns[row]
        if id == "column" {
            let label = NSTextField(labelWithString: column.type.isEmpty ? column.name : "\(column.name)  \(column.type)")
            label.lineBreakMode = .byTruncatingTail
            // Centered in the row, level with the menu beside it.
            let cell = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        let popUp = NSPopUpButton()
        popUp.addItem(withTitle: tr("（不匯入）", "(Don’t import)"))
        for i in 0..<fieldCount { popUp.addItem(withTitle: fieldName(i)) }
        popUp.selectItem(at: plan.sources[row].map { $0 + 1 } ?? 0)
        popUp.tag = row
        popUp.target = self
        popUp.action = #selector(sourceChanged(_:))
        popUp.controlSize = .small
        return popUp
    }

    // MARK: Actions

    @objc private func sourceChanged(_ sender: NSPopUpButton) {
        guard plan.sources.indices.contains(sender.tag) else { return }
        plan.sources[sender.tag] = sender.indexOfSelectedItem == 0 ? nil : sender.indexOfSelectedItem - 1
        update()
    }

    @objc private func separatorChanged(_ sender: NSPopUpButton) {
        separator = CSV.separators[safe: sender.indexOfSelectedItem] ?? ","
        reparse()
    }

    @objc private func optionsChanged(_ sender: NSButton) {
        if sender === headerCheck { rematch() } else { update() }
    }

    @objc private func importClicked(_ sender: Any?) {
        update()
        guard importButton.isEnabled else { return NSSound.beep() }
        result = plan
        NSApp.stopModal(withCode: .OK)
        panel.orderOut(nil)
    }

    /// The title bar's close button: the same as Cancel.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel(sender)
        return false
    }

    @objc private func cancel(_ sender: Any?) {
        result = nil
        NSApp.stopModal(withCode: .cancel)
        panel.orderOut(nil)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
