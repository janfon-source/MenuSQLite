import AppKit

/// Shows a ResultSet in a table, a column per result column. Clicking a header asks for the rows
/// sorted by it (`onSort`); when `editable`, double-clicking a cell edits it (`onEdit`), and the
/// right-click menu can set a cell to NULL. ⌘C copies the selected rows as tab-separated text.
final class Grid: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let tableView = GridTableView()
    let scrollView = NSScrollView()
    private(set) var result = ResultSet()

    var editable = false
    var onEdit: ((_ row: Int, _ column: Int, _ value: Value) -> Void)?
    var onSort: ((_ column: String, _ ascending: Bool) -> Void)?
    /// Columns left out of view, by name. They're still in `result`, and still edited and sorted
    /// by name; they just aren't shown or copied.
    var hiddenColumns: Set<String> = [] {
        didSet { applyHiddenColumns() }
    }

    /// More right-click items, such as deleting rows, added after the grid's own.
    var extraMenuItems: () -> [NSMenuItem] = { [] }

    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    override init() {
        super.init()
        tableView.grid = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.rowHeight = 20
        tableView.style = .plain
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
    }

    /// Shows new rows. The columns are rebuilt only when they change, so paging through a table
    /// keeps the widths the user dragged.
    func show(_ result: ResultSet, sortedBy sort: (column: String, ascending: Bool)? = nil) {
        self.result = result
        if tableView.tableColumns.map(\.title) != result.columns {
            tableView.tableColumns.forEach(tableView.removeTableColumn)
            for (i, name) in result.columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(i)))
                column.title = name
                column.minWidth = 40
                column.width = width(of: i)
                column.sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)
                let cell = NSTextFieldCell()
                cell.font = font
                cell.lineBreakMode = .byTruncatingTail
                cell.isEditable = true
                column.dataCell = cell
                tableView.addTableColumn(column)
            }
        }
        // Show the sort the rows came in, without asking for them again.
        let descriptors = sort.map { [NSSortDescriptor(key: $0.column, ascending: $0.ascending)] } ?? []
        if tableView.sortDescriptors != descriptors {
            let handler = onSort
            onSort = nil
            tableView.sortDescriptors = descriptors
            onSort = handler
        }
        applyHiddenColumns()
        tableView.reloadData()
    }

    private func applyHiddenColumns() {
        for column in tableView.tableColumns { column.isHidden = hiddenColumns.contains(column.title) }
    }

    /// Wide enough for the header and the first rows, within reason.
    private func width(of column: Int) -> CGFloat {
        let header = (result.columns[column] as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12)]).width
        let cells = result.rows.prefix(50).map {
            (text(of: $0[column]) as NSString).size(withAttributes: [.font: font]).width
        }
        return min(320, max(60, header + 24, (cells.max() ?? 0) + 16))
    }

    /// A cell's text on one line.
    private func text(of value: Value) -> String {
        value.display.replacingOccurrences(of: "\n", with: "⏎")
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { result.rows.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }) else { return nil }
        return text(of: result.rows[row][column])
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        guard editable, let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }) else { return false }
        if case .blob = result.rows[row][column] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        guard let cell = cell as? NSTextFieldCell, let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }),
              row < result.rows.count else { return }
        let value = result.rows[row][column]
        switch value {
        case .null, .blob:
            cell.textColor = .tertiaryLabelColor
            cell.font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        default:
            cell.textColor = .labelColor
            cell.font = font
        }
        // Numbers line up on the right, as in a spreadsheet.
        switch value {
        case .integer, .real: cell.alignment = .right
        default: cell.alignment = .left
        }
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }), let text = object as? String,
              text != self.text(of: result.rows[row][column]) else { return }
        onEdit?(row, column, .text(text))
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        onSort?(key, descriptor.ascending)
    }

    // MARK: Menu and copying

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow, column = tableView.clickedColumn
        // A right-click outside the selection selects the row it's on, as Finder does.
        if row >= 0, !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        let copy = NSMenuItem(title: tr("拷貝", "Copy"), action: #selector(GridTableView.copy(_:)), keyEquivalent: "")
        copy.target = tableView
        menu.addItem(copy)
        if editable, row >= 0, column >= 0, result.rows[row][column] != .null {
            let null = NSMenuItem(title: tr("設為 NULL", "Set to NULL"), action: #selector(setNull(_:)), keyEquivalent: "")
            null.target = self
            null.representedObject = [row, column]
            menu.addItem(null)
        }
        let extra = extraMenuItems()
        if !extra.isEmpty {
            menu.addItem(.separator())
            extra.forEach(menu.addItem)
        }
    }

    @objc private func setNull(_ sender: NSMenuItem) {
        guard let place = sender.representedObject as? [Int] else { return }
        onEdit?(place[0], place[1], .null)
    }

    /// The selected rows (or all, with none selected) as tab-separated text, the header first.
    func copySelection() {
        let rows = tableView.selectedRowIndexes.isEmpty ? IndexSet(result.rows.indices) : tableView.selectedRowIndexes
        guard !rows.isEmpty else { return }
        let shown = result.columns.indices.filter { !hiddenColumns.contains(result.columns[$0]) }
        let lines = [shown.map { result.columns[$0] }.joined(separator: "\t")]
            + rows.map { row in shown.map { result.rows[row][$0] }
                .map { $0 == .null ? "" : text(of: $0).replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

final class GridTableView: NSTableView {
    weak var grid: Grid?

    @objc func copy(_ sender: Any?) {
        grid?.copySelection()
    }
}
