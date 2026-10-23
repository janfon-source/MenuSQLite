import AppKit

/// A window listing the favorite databases, to add, copy, edit and delete them, put them in order
/// by dragging, and open one (with Open, or a double-click).
final class FavoritesWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private var favorites = Favorites.all
    private let table = NSTableView()
    private var copyButton: NSButton!
    private var editButton: NSButton!
    private var removeButton: NSButton!
    private var connectButton: NSButton!

    /// The favorite to connect to, once the window closes with Connect.
    private(set) var chosen: Favorite?

    var window: NSWindow { panel }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = tr("常用資料庫", "Favorite Databases")
        panel.minSize = NSSize(width: 480, height: 280)
        panel.delegate = self
        build()
        updateButtons()
    }

    /// Shows the window until it's closed.
    func run() {
        panel.center()
        panel.makeFirstResponder(table)
        if !favorites.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        NSApp.runModal(for: panel)
    }

    // MARK: Layout

    private enum Field: String, CaseIterable {
        case name, location
        var title: String {
            switch self {
            case .name: return tr("名稱", "Name")
            case .location: return tr("位置", "Location")
            }
        }
        var width: CGFloat { self == .location ? 400 : 170 }
    }

    private func build() {
        for field in Field.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(field.rawValue))
            column.title = field.title
            column.width = field.width
            column.minWidth = 80
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(connect(_:))
        // Rows are dragged into the order the star menu lists them in.
        table.registerForDraggedTypes([Self.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        func button(_ symbol: String, _ zh: String, _ en: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tr(zh, en))!,
                                  target: self, action: action)
            button.bezelStyle = .smallSquare
            button.toolTip = tr(zh, en)
            return button
        }
        copyButton = button("plus.square.on.square", "複製", "Duplicate", #selector(duplicate(_:)))
        editButton = button("pencil", "編輯", "Edit", #selector(edit(_:)))
        removeButton = button("minus", "刪除", "Delete", #selector(remove(_:)))
        let listButtons = NSStackView(views: [button("plus", "新增", "Add", #selector(add(_:))), removeButton,
                                              copyButton, editButton, NSView()])
        listButtons.spacing = 4

        let close = NSButton(title: tr("關閉", "Close"), target: self, action: #selector(closeWindow(_:)))
        close.keyEquivalent = "\u{1b}"
        connectButton = NSButton(title: tr("開啟", "Open"), target: self, action: #selector(connect(_:)))
        connectButton.keyEquivalent = "\r"
        let actions = NSStackView(views: [NSView(), close, connectButton])

        let stack = NSStackView(views: [scroll, listButtons, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        for view in [scroll, listButtons, actions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
        ])
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { favorites.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let favorite = favorites[row]
        switch tableColumn.flatMap({ Field(rawValue: $0.identifier.rawValue) }) {
        case .name: return favorite.name
        case .location: return favorite.summary
        case nil: return nil
        }
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool { false }

    // MARK: Dragging into order

    private static let rowType = NSPasteboard.PasteboardType("com.jeff.menumysql.favorite-row")

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table else { return [] }
        tableView.setDropRow(row, dropOperation: .above)   // between rows, never onto one
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowType),
              let from = Int(text), favorites.indices.contains(from) else { return false }
        let to = from < row ? row - 1 : row
        guard to != from else { return false }
        favorites.insert(favorites.remove(at: from), at: to)
        save(selecting: to)
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private var selected: Int? { favorites.indices.contains(table.selectedRow) ? table.selectedRow : nil }

    private func updateButtons() {
        for button in [copyButton, editButton, removeButton, connectButton] { button?.isEnabled = selected != nil }
    }

    /// Saves the list and shows it, with `row` selected.
    private func save(selecting row: Int?) {
        Favorites.all = favorites
        table.reloadData()
        if let row, favorites.indices.contains(row) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        updateButtons()
    }

    // MARK: Actions

    @objc private func add(_ sender: Any?) {
        guard let favorite = Self.edit(nil) else { return }
        favorites.append(favorite)
        save(selecting: favorites.count - 1)
    }

    @objc private func duplicate(_ sender: Any?) {
        guard let row = selected else { return NSSound.beep() }
        var copy = favorites[row]
        copy.id = UUID()
        copy.name += tr(" 副本", " copy")
        favorites.insert(copy, at: row + 1)
        save(selecting: row + 1)
    }

    @objc private func edit(_ sender: Any?) {
        guard let row = selected, let favorite = Self.edit(favorites[row]) else { return }
        favorites[row] = favorite
        save(selecting: row)
    }

    @objc private func remove(_ sender: Any?) {
        guard let row = selected else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = tr("要刪除常用資料庫「\(favorites[row].name)」嗎？", "Delete the favorite “\(favorites[row].name)”?")
        alert.informativeText = tr("只從清單移除，伺服器上的資料庫不受影響。", "It only leaves this list; the database on the server is untouched.")
        alert.addButton(withTitle: tr("刪除", "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        favorites.remove(at: row)
        save(selecting: min(row, favorites.count - 1))
    }

    @objc private func connect(_ sender: Any?) {
        guard let row = selected else { return }
        chosen = favorites[row]
        panel.close()
    }

    @objc private func closeWindow(_ sender: Any?) {
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }

    // MARK: Editing one

    /// Asks for a favorite's name and where the database is, starting from `favorite` (nil for a
    /// new one, which starts from `start`, a recent-list key). Nil if cancelled.
    static func edit(_ favorite: Favorite?, start: String? = nil) -> Favorite? {
        let form = FavoriteForm(name: favorite?.name ?? "", key: favorite?.key ?? start)
        let alert = NSAlert()
        alert.messageText = favorite == nil ? tr("新增常用資料庫", "New Favorite Database") : tr("編輯常用資料庫", "Edit Favorite Database")
        alert.informativeText = tr("名稱留空時，用檔案名稱。", "Left empty, the name is the file’s.")
        alert.accessoryView = form.view
        alert.addButton(withTitle: tr("儲存", "Save"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.window.initialFirstResponder = form.firstField
        while alert.runModal() == .alertFirstButtonReturn {
            guard let key = form.key else {
                let warning = NSAlert()
                warning.alertStyle = .warning
                warning.messageText = form.isRemote ? tr("請輸入主機和資料庫路徑。", "Enter the server and the database’s path.")
                                                    : tr("請選擇資料庫檔案。", "Choose the database file.")
                warning.runModal()
                continue
            }
            let name = form.name.isEmpty ? Favorites.suggestedName(for: key) : form.name
            return Favorite(id: favorite?.id ?? UUID(), name: name, key: key)
        }
        return nil
    }
}

/// The fields for a favorite: its name, and a file on this Mac or a database on a server. Both
/// kinds' fields are always there, the one not chosen greyed out, so the alert keeps its size.
private final class FavoriteForm: NSObject {
    let view: NSStackView
    private let nameField = NSTextField()
    private let kind = NSSegmentedControl()
    private let pathField = NSTextField()
    private let choose = NSButton()
    private let remote: RemoteForm

    var isRemote: Bool { kind.selectedSegment == 1 }
    var name: String { nameField.stringValue.trimmingCharacters(in: .whitespaces) }
    var firstField: NSView { nameField.stringValue.isEmpty ? nameField : isRemote ? remote.firstField : pathField }

    /// Where it is, as a recent-list key; nil while that's missing.
    var key: String? {
        if isRemote { return remote.location?.key }
        let path = (pathField.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        return path.isEmpty ? nil : path
    }

    init(name: String, key: String?) {
        let location = key.flatMap(RemoteLocation.init(key:))
        let remotes = UserDefaults.standard.stringArray(forKey: "menusqlite.recent")?.compactMap(RemoteLocation.init(key:)) ?? []
        remote = RemoteForm(start: location ?? remotes.first) { alias in remotes.first { $0.destination == alias }?.path }
        nameField.stringValue = name
        nameField.placeholderString = tr("例如：訂單資料庫", "e.g. Orders")
        pathField.stringValue = location == nil ? ((key ?? "") as NSString).abbreviatingWithTildeInPath : ""
        pathField.placeholderString = "~/Documents/app.sqlite"
        for field in [nameField, pathField] { field.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        choose.title = tr("選擇…", "Choose…")
        choose.bezelStyle = .rounded
        kind.segmentCount = 2
        kind.setLabel(tr("本機檔案", "File on This Mac"), forSegment: 0)
        kind.setLabel(tr("伺服器（SSH）", "On a Server (SSH)"), forSegment: 1)
        kind.selectedSegment = location == nil ? 0 : 1
        let top = NSGridView(views: [
            [NSTextField(labelWithString: tr("名稱", "Name")), nameField],
            [NSTextField(labelWithString: tr("位置", "Location")), kind],
            [NSTextField(labelWithString: tr("檔案", "File")), NSStackView(views: [pathField, choose])],
        ])
        top.column(at: 0).xPlacement = .trailing
        top.rowAlignment = .firstBaseline
        let line = NSBox()
        line.boxType = .separator
        view = NSStackView(views: [top, line, remote.view])
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 10
        super.init()
        line.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        kind.target = self
        kind.action = #selector(kindChanged(_:))
        choose.target = self
        choose.action = #selector(chooseFile(_:))
        applyKind()
        view.frame.size = view.fittingSize
    }

    @objc private func kindChanged(_ sender: Any?) {
        applyKind()
        view.window?.makeFirstResponder(isRemote ? remote.firstField : pathField)
    }

    private func applyKind() {
        pathField.isEnabled = !isRemote
        choose.isEnabled = !isRemote
        remote.isEnabled = isRemote
    }

    @objc private func chooseFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = tr("選擇 SQLite 資料庫檔案", "Choose an SQLite database file")
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.pathField.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}
