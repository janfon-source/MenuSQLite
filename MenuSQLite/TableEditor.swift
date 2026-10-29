import AppKit

/// A window for designing a new table, or the Edit tab's editor for changing one: its name, and a row per column with
/// type, length, key, NOT NULL, UNIQUE and default (dragged by the handle at the left to reorder). The SQL it will run shows below as it's edited,
/// with any warning, such as a column's data being deleted.
final class TableEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSComboBoxDelegate, NSWindowDelegate {
    /// The window of a new table's editor; nil for one in the Edit tab.
    private let panel: NSPanel?
    /// Everything the editor shows: the window's content, or the Edit tab's.
    let view = NSView()
    /// For an editor in the Edit tab: Save hands it the SQL and the name, and Cancel becomes Revert.
    private let onSave: ((_ sql: String, _ name: String) -> Void)?
    private let snapshot: TableSnapshot?
    private var columns: [ColumnDraft]
    private var indexes: [IndexDraft]
    private let nameField = NSTextField()
    private let table = NSTableView()
    private let indexTable = NSTableView()
    private var removeIndexButton: NSButton!
    private let message = NSTextField(wrappingLabelWithString: "")
    private let preview = NSTextView.scrollableTextView()
    private var previewText: NSTextView { preview.documentView as! NSTextView }
    private var saveButton: NSButton!
    private var cancelButton: NSButton!
    /// In the Edit tab: whether the design differs from the table as it is.
    private(set) var hasChanges = false
    private var removeButton: NSButton!
    private var upButton: NSButton!
    private var downButton: NSButton!

    /// The SQL to run, once the window closes with Save.
    private(set) var sql: String?
    /// The table's name as entered, to select it once it's made.
    var tableName: String { nameField.stringValue.trimmingCharacters(in: .whitespaces) }

    private enum Field: String, CaseIterable {
        case handle, name, type, length, primaryKey, notNull, unique, defaultValue
        var title: String {
            switch self {
            case .handle: return ""
            case .length: return tr("長度", "Length")
            case .name: return tr("名稱", "Name")
            case .type: return tr("類型", "Type")
            case .primaryKey: return tr("主鍵", "Key")
            case .notNull: return tr("非空", "Not Null")
            case .unique: return tr("唯一", "Unique")
            case .defaultValue: return tr("預設值", "Default")
            }
        }
        var width: CGFloat {
            switch self {
            case .handle: return 22
            case .length: return 70
            case .name: return 150
            case .type: return 110
            case .primaryKey, .notNull, .unique: return 44
            case .defaultValue: return 140
            }
        }
    }

    private enum IndexField: String, CaseIterable {
        case indexName, kind, indexColumns
        var title: String {
            switch self {
            case .indexName: return tr("索引名稱", "Index Name")
            case .kind: return tr("類型", "Kind")
            case .indexColumns: return tr("欄位（可加 DESC 或 COLLATE NOCASE）", "Columns (with DESC or COLLATE NOCASE)")
            }
        }
        var width: CGFloat {
            switch self {
            case .indexName: return 170
            case .kind: return 100
            case .indexColumns: return 330
            }
        }
    }

    /// For a new table, `snapshot` is nil. With `onSave`, the editor goes in the Edit tab rather
    /// than a window of its own.
    init(snapshot: TableSnapshot?, onSave: ((_ sql: String, _ name: String) -> Void)? = nil) {
        self.snapshot = snapshot
        self.onSave = onSave
        columns = snapshot?.columns ?? [ColumnDraft(name: "id", type: "INTEGER", primaryKey: true, autoincrement: true)]
        indexes = snapshot?.indexDrafts ?? []
        panel = onSave != nil ? nil : NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
                                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        if let panel {
            panel.delegate = self
            panel.title = snapshot == nil ? tr("新增資料表", "New Table") : tr("編輯資料表「\(snapshot!.name)」", "Edit Table “\(snapshot!.name)”")
            panel.minSize = NSSize(width: 640, height: 580)
            panel.contentView = view
        }
        build()
        update()
    }

    /// Shows the window until it's closed; true if Save was clicked.
    func run() -> Bool {
        guard let panel else { return false }
        panel.center()
        panel.makeFirstResponder(snapshot == nil ? nameField : table)
        return NSApp.runModal(for: panel) == .OK
    }

    // MARK: Layout

    private func build() {
        nameField.stringValue = snapshot?.name ?? ""
        nameField.placeholderString = tr("資料表名稱", "Table name")
        nameField.delegate = self
        let nameRow = NSStackView(views: [NSTextField(labelWithString: tr("名稱", "Name")), nameField])

        for field in Field.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(field.rawValue))
            column.title = field.title
            column.width = field.width
            column.minWidth = field.width * 0.6
            if field == .handle {
                column.minWidth = field.width
                column.maxWidth = field.width
                column.headerToolTip = tr("拖曳這裡可以調整欄位順序", "Drag here to reorder the columns")
            }
            table.addTableColumn(column)
        }
        // Rows are dragged by the handle (or anywhere not taken by a control) into a new order.
        table.registerForDraggedTypes([Self.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder

        func button(_ symbol: String, _ zh: String, _ en: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tr(zh, en))!,
                                  target: self, action: action)
            button.bezelStyle = .smallSquare
            button.toolTip = tr(zh, en)
            return button
        }
        removeButton = button("minus", "刪除欄位", "Remove Column", #selector(removeColumn(_:)))
        upButton = button("arrow.up", "上移", "Move Up", #selector(moveUp(_:)))
        downButton = button("arrow.down", "下移", "Move Down", #selector(moveDown(_:)))
        let columnButtons = NSStackView(views: [button("plus", "新增欄位", "Add Column", #selector(addColumn(_:))),
                                                removeButton, upButton, downButton, NSView()])
        columnButtons.spacing = 4

        // The indexes made with CREATE INDEX; the key and UNIQUE ones are the checkboxes above.
        for field in IndexField.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(field.rawValue))
            column.title = field.title
            column.width = field.width
            column.minWidth = field == .kind ? 90 : 120
            indexTable.addTableColumn(column)
        }
        indexTable.dataSource = self
        indexTable.delegate = self
        indexTable.rowHeight = 30
        indexTable.usesAlternatingRowBackgroundColors = true
        indexTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let indexScroll = NSScrollView()
        indexScroll.documentView = indexTable
        indexScroll.hasVerticalScroller = true
        indexScroll.borderType = .bezelBorder
        // Smaller in the Edit tab, which has less room than a window and scrolls when short of it.
        let inTab = panel == nil
        indexScroll.heightAnchor.constraint(equalToConstant: inTab ? 90 : 120).isActive = true
        let indexTitle = NSTextField(labelWithString: tr("索引", "Indexes"))
        indexTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let indexHint = NSTextField(labelWithString: tr("主鍵和單一欄位的唯一限制，用上方欄位的「主鍵」「唯一」勾選。",
                                                        "The key and single-column UNIQUE constraints are the Key and Unique boxes above."))
        indexHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        indexHint.textColor = .secondaryLabelColor
        indexHint.lineBreakMode = .byTruncatingTail
        indexHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let indexHeader = NSStackView(views: [indexTitle, indexHint])
        indexHeader.alignment = .firstBaseline
        removeIndexButton = button("minus", "刪除索引", "Remove Index", #selector(removeIndex(_:)))
        let indexButtons = NSStackView(views: [button("plus", "新增索引", "Add Index", #selector(addIndex(_:))), removeIndexButton, NSView()])
        indexButtons.spacing = 4

        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        previewText.isEditable = false
        previewText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewText.textContainerInset = NSSize(width: 6, height: 6)
        preview.borderType = .bezelBorder
        preview.hasVerticalScroller = true
        preview.heightAnchor.constraint(equalToConstant: inTab ? 90 : 150).isActive = true

        saveButton = NSButton(title: snapshot == nil ? tr("建立", "Create") : tr("儲存", "Save"), target: self, action: #selector(save(_:)))
        cancelButton = NSButton(title: inTab ? tr("還原", "Revert") : tr("取消", "Cancel"), target: self, action: #selector(cancel(_:)))
        // Return and Esc belong to the window's own editor; in the tab, Esc hides the window.
        if !inTab {
            saveButton.keyEquivalent = "\r"
            cancelButton.keyEquivalent = "\u{1b}"
        }
        let actions = NSStackView(views: [NSView(), cancelButton, saveButton])

        let stack = NSStackView(views: [nameRow, tableScroll, columnButtons, indexHeader, indexScroll, indexButtons, message,
                                        NSTextField(labelWithString: tr("將執行的 SQL", "SQL to Run")), preview, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.distribution = .fill
        let inset: CGFloat = inTab ? 12 : 16
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        stack.setCustomSpacing(14, after: columnButtons)
        for view in [nameRow, tableScroll, columnButtons, indexHeader, indexScroll, indexButtons, message, preview, actions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * inset).isActive = true
        }
        tableScroll.setContentHuggingPriority(.init(1), for: .vertical)
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: inTab ? 110 : 140).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: The column table

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === indexTable ? indexes.count : columns.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === indexTable { return indexCell(tableColumn, row: row) }
        guard let field = tableColumn.flatMap({ Field(rawValue: $0.identifier.rawValue) }) else { return nil }
        let column = columns[row]
        switch field {
        case .handle:
            let grip = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal",
                                                  accessibilityDescription: tr("拖曳以調整順序", "Drag to reorder"))!)
            grip.contentTintColor = .tertiaryLabelColor
            grip.toolTip = tr("拖曳以調整順序", "Drag to reorder")
            return centered(grip)
        case .length:
            let parts = TableDesign.split(column.type)
            let text = NSTextField(string: parts.length)
            text.isBordered = false
            text.drawsBackground = false
            text.placeholderString = TableDesign.lengthHint(for: parts.base)
            text.toolTip = tr("SQLite 不會限制長度，只是記錄在建立語句裡。", "SQLite doesn’t enforce it; it’s only written in the CREATE statement.")
            text.isEditable = !TableDesign.lengthless.contains(parts.base.split(separator: " ").first.map { $0.uppercased() } ?? "")
            text.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            text.delegate = self
            return centered(text, fill: true)
        case .primaryKey, .notNull, .unique:
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            box.state = (field == .primaryKey ? column.primaryKey : field == .notNull ? column.notNull : column.unique) ? .on : .off
            return centered(box)
        case .type:
            let combo = NSComboBox()
            combo.addItems(withObjectValues: TableDesign.types)
            combo.stringValue = TableDesign.split(column.type).base
            combo.isBordered = false
            combo.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            combo.delegate = self
            return centered(combo, fill: true)
        case .name, .defaultValue:
            let text = NSTextField(string: field == .name ? column.name : column.defaultValue)
            text.isBordered = false
            text.drawsBackground = false
            text.placeholderString = field == .defaultValue ? tr("（無）", "(none)") : nil
            text.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            text.delegate = self
            return centered(text, fill: true)
        }
    }

    /// Centered in its cell, vertically and either horizontally (checkboxes) or across its width.
    private func centered(_ view: NSView, fill: Bool = false) -> NSView {
        let holder = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(view)
        NSLayoutConstraint.activate(fill
            ? [view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 2),
               view.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -2),
               view.centerYAnchor.constraint(equalTo: holder.centerYAnchor)]
            : [view.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
               view.centerYAnchor.constraint(equalTo: holder.centerYAnchor)])
        return holder
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    @objc private func toggled(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard columns.indices.contains(row), let field = sender.identifier.flatMap({ Field(rawValue: $0.rawValue) }) else { return }
        let on = sender.state == .on
        switch field {
        case .primaryKey: columns[row].primaryKey = on
        case .notNull: columns[row].notNull = on
        case .unique: columns[row].unique = on
        default: break
        }
        update()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === nameField { return update() }
        if let indexField = field.identifier.flatMap({ IndexField(rawValue: $0.rawValue) }) {
            let row = indexTable.row(for: field)
            guard indexes.indices.contains(row) else { return }
            if indexField == .indexName { indexes[row].name = field.stringValue.trimmingCharacters(in: .whitespaces) }
            else { indexes[row].columns = IndexDraft.columns(from: field.stringValue) }
            return update()
        }
        let row = table.row(for: field)
        guard columns.indices.contains(row) else { return }
        switch field.identifier?.rawValue {
        case Field.name.rawValue:
            renameInIndexes(columns[row].name, to: field.stringValue)
            columns[row].name = field.stringValue
        case Field.type.rawValue:
            columns[row].type = TableDesign.join(field.stringValue, TableDesign.split(columns[row].type).length)
            reloadLength(of: row)
        case Field.length.rawValue: columns[row].type = TableDesign.join(TableDesign.split(columns[row].type).base, field.stringValue)
        case Field.defaultValue.rawValue: columns[row].defaultValue = field.stringValue
        default: break
        }
        update()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox, combo.indexOfSelectedItem >= 0 else { return }
        let row = table.row(for: combo)
        guard columns.indices.contains(row) else { return }
        let old = TableDesign.split(columns[row].type), base = TableDesign.types[combo.indexOfSelectedItem]
        columns[row].type = TableDesign.join(base, TableDesign.length(changingType: old.base, to: base, from: old.length))
        reloadLength(of: row)
        update()
    }

    /// Shows the row's length again, after its type changed: a new one, or a field that's off.
    private func reloadLength(of row: Int) {
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == Field.length.rawValue }) else { return }
        table.reloadData(forRowIndexes: [row], columnIndexes: [column])
    }

    // MARK: Dragging into order

    private static let rowType = NSPasteboard.PasteboardType("com.jeff.menusqlite.column-row")

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableView === table else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === table, info.draggingSource as? NSTableView === table else { return [] }
        tableView.setDropRow(row, dropOperation: .above)   // between rows, never onto one
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard tableView === table, let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowType),
              let from = Int(text) else { return false }
        return moveColumn(from: from, to: row)
    }

    /// Moves a column to before the row at `to` (or to the end); false if it stays where it was.
    @discardableResult
    func moveColumn(from: Int, to row: Int) -> Bool {
        guard columns.indices.contains(from) else { return false }
        let to = from < row ? row - 1 : row
        guard to != from, columns.indices.contains(to) else { return false }
        view.window?.makeFirstResponder(nil)   // the text typed so far counts
        columns.insert(columns.remove(at: from), at: to)
        table.reloadData()
        table.selectRowIndexes([to], byExtendingSelection: false)
        update()
        return true
    }

    // MARK: Adding and moving columns

    @objc private func addColumn(_ sender: Any?) {
        var name = tr("新欄位", "column"), n = 1
        while columns.contains(where: { $0.name == name }) { n += 1; name = tr("新欄位\(n)", "column\(n)") }
        columns.append(ColumnDraft(name: name, type: "TEXT"))
        table.reloadData()
        let row = columns.count - 1
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        table.editColumn(table.column(withIdentifier: NSUserInterfaceItemIdentifier(Field.name.rawValue)), row: row, with: nil, select: true)
        update()
    }

    @objc private func removeColumn(_ sender: Any?) {
        let row = table.selectedRow
        guard columns.indices.contains(row) else { return }
        // Its indexes lose it; an index left with no column goes too.
        let removed = columns.remove(at: row).name
        for i in indexes.indices { indexes[i].columns.removeAll { IndexDraft.column(of: $0) == removed } }
        indexes.removeAll { $0.columns.isEmpty }
        indexTable.reloadData()
        table.reloadData()
        if !columns.isEmpty { table.selectRowIndexes([min(row, columns.count - 1)], byExtendingSelection: false) }
        update()
    }

    @objc private func moveUp(_ sender: Any?) { move(by: -1) }
    @objc private func moveDown(_ sender: Any?) { move(by: 1) }

    private func move(by step: Int) {
        let row = table.selectedRow, target = row + step
        guard columns.indices.contains(row), columns.indices.contains(target) else { return }
        columns.swapAt(row, target)
        table.reloadData()
        table.selectRowIndexes([target], byExtendingSelection: false)
        update()
    }

    // MARK: Indexes

    private func indexCell(_ tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let field = tableColumn.flatMap({ IndexField(rawValue: $0.identifier.rawValue) }) else { return nil }
        let index = indexes[row]
        switch field {
        case .kind:
            let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            popUp.controlSize = .small
            popUp.addItems(withTitles: IndexDraft.Kind.allCases.map(\.rawValue))
            popUp.selectItem(withTitle: index.kind.rawValue)
            popUp.target = self
            popUp.action = #selector(kindChanged(_:))
            return centered(popUp, fill: true)
        case .indexName, .indexColumns:
            let text = NSTextField(string: field == .indexName ? index.name : index.columnsText)
            text.isBordered = false
            text.drawsBackground = false
            text.placeholderString = field == .indexName ? tr("索引名稱（必填）", "Index name (required)") : tr("例如 name, created DESC", "e.g. name, created DESC")
            text.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
            text.delegate = self
            guard field == .indexColumns else { return centered(text, fill: true) }
            // Beside the columns, a menu of the table's columns to tick in or out.
            let pick = NSButton(image: NSImage(systemSymbolName: "list.bullet", accessibilityDescription: tr("選擇欄位", "Choose Columns"))!,
                                target: self, action: #selector(showIndexColumns(_:)))
            pick.isBordered = false
            pick.toolTip = tr("選擇欄位", "Choose Columns")
            pick.setContentHuggingPriority(.required, for: .horizontal)
            text.setContentHuggingPriority(.init(1), for: .horizontal)
            return centered(NSStackView(views: [text, pick]), fill: true)
        }
    }

    @objc private func kindChanged(_ sender: NSPopUpButton) {
        let row = indexTable.row(for: sender)
        guard indexes.indices.contains(row), let kind = sender.titleOfSelectedItem.flatMap(IndexDraft.Kind.init(rawValue:)) else { return }
        indexes[row].kind = kind
        update()
    }

    @objc private func showIndexColumns(_ sender: NSButton) {
        let row = indexTable.row(for: sender)
        guard indexes.indices.contains(row) else { return }
        indexTable.selectRowIndexes([row], byExtendingSelection: false)
        view.window?.makeFirstResponder(nil)   // the text typed so far counts
        let menu = NSMenu()
        let used = indexes[row].columns.map(IndexDraft.column(of:))
        for column in columns where !column.name.isEmpty {
            let item = menu.addItem(withTitle: column.name, action: #selector(toggleIndexColumn(_:)), keyEquivalent: "")
            item.target = self
            item.state = used.contains(column.name) ? .on : .off
            item.tag = row
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    /// Adds the column at the end of the index, or takes it out.
    @objc private func toggleIndexColumn(_ sender: NSMenuItem) {
        let row = sender.tag
        guard indexes.indices.contains(row) else { return }
        if sender.state == .on {
            indexes[row].columns.removeAll { IndexDraft.column(of: $0) == sender.title }
        } else {
            indexes[row].columns.append(sender.title)
        }
        indexTable.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<indexTable.numberOfColumns))
        update()
    }

    @objc private func addIndex(_ sender: Any?) {
        // Index names are the database's, not the table's, so the table's name goes in them.
        let start = columns.indices.contains(table.selectedRow) ? [columns[table.selectedRow].name] : []
        let base = "idx_" + tableName + (start.first.map { "_" + $0 } ?? "")
        var name = base, n = 1
        while indexes.contains(where: { $0.name.lowercased() == name.lowercased() }) { n += 1; name = base + "\(n)" }
        indexes.append(IndexDraft(name: name, columns: start))
        indexTable.reloadData()
        let row = indexes.count - 1
        indexTable.selectRowIndexes([row], byExtendingSelection: false)
        indexTable.scrollRowToVisible(row)
        indexTable.editColumn(0, row: row, with: nil, select: true)
        update()
    }

    @objc private func removeIndex(_ sender: Any?) {
        let row = indexTable.selectedRow
        guard indexes.indices.contains(row) else { return }
        indexes.remove(at: row)
        indexTable.reloadData()
        if !indexes.isEmpty { indexTable.selectRowIndexes([min(row, indexes.count - 1)], byExtendingSelection: false) }
        update()
    }

    /// A column renamed in the grid keeps its place in the indexes.
    private func renameInIndexes(_ old: String, to new: String) {
        guard old != new, !old.isEmpty else { return }
        var changed = false
        for i in indexes.indices {
            for j in indexes[i].columns.indices where IndexDraft.column(of: indexes[i].columns[j]) == old {
                indexes[i].columns[j] = IndexDraft.renaming(indexes[i].columns[j], to: new)
                changed = true
            }
        }
        if changed { indexTable.reloadData() }
    }

    private func updateButtons() {
        removeIndexButton?.isEnabled = indexes.indices.contains(indexTable.selectedRow)
        let row = table.selectedRow
        removeButton.isEnabled = row >= 0
        upButton.isEnabled = row > 0
        downButton.isEnabled = row >= 0 && row < columns.count - 1
    }

    // MARK: SQL

    /// Remakes the SQL preview and the message, and enables Save when there's something valid to do.
    private func update() {
        updateButtons()
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if let problem = TableDesign.problem(name: name, columns: columns, indexes: indexes) {
            show(sql: "", message: problem, error: true)
            hasChanges = true
            if panel == nil { cancelButton.isEnabled = true }
            return
        }
        guard let snapshot else {
            show(sql: TableDesign.createSQL(name: name, columns: columns, indexes: indexes), message: "", error: false)
            return
        }
        let change = TableDesign.alterSQL(snapshot, newName: name, columns: columns, indexes: indexes)
        let unchanged = change.sql.isEmpty
        show(sql: unchanged ? "" : change.sql,
             message: unchanged ? tr("沒有變更。", "Nothing has changed.") : change.warnings.joined(separator: "\n"),
             error: false, canSave: !unchanged)
        hasChanges = !unchanged
        if panel == nil { cancelButton.isEnabled = !unchanged }
    }

    private func show(sql: String, message text: String, error: Bool, canSave: Bool? = nil) {
        let attributed = NSMutableAttributedString(string: sql, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor])
        SyntaxHighlighter.highlight(attributed, language: "sql")
        previewText.textStorage?.setAttributedString(attributed)
        message.stringValue = text
        message.textColor = error ? .systemRed : .systemOrange
        message.isHidden = text.isEmpty
        saveButton.isEnabled = canSave ?? !error
        self.sql = sql.isEmpty ? nil : sql
    }

    @objc private func save(_ sender: Any?) {
        view.window?.makeFirstResponder(nil)   // finish the cell being typed in
        update()
        guard let sql, saveButton.isEnabled else { return NSSound.beep() }
        if let onSave { return onSave(sql, tableName) }
        NSApp.stopModal(withCode: .OK)
        panel?.orderOut(nil)
    }

    /// The title bar's close button: the same as Cancel.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel(sender)
        return false
    }

    @objc private func cancel(_ sender: Any?) {
        guard let panel else { return revert() }
        sql = nil
        NSApp.stopModal(withCode: .cancel)
        panel.orderOut(nil)
    }

    /// In the Edit tab: back to the table as it is, dropping the changes.
    private func revert() {
        guard let snapshot else { return }
        view.window?.makeFirstResponder(nil)
        nameField.stringValue = snapshot.name
        columns = snapshot.columns
        indexes = snapshot.indexDrafts
        table.reloadData()
        indexTable.reloadData()
        update()
    }
}
