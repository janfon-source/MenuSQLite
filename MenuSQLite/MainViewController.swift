import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/// The popover's content: the open database's tables on the left, and on the right a table's
/// rows, its structure, or an SQL query and its results.
final class MainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                NSTextViewDelegate, NSOpenSavePanelDelegate {
    weak var popover: NSPopover?

    private(set) var database: Database?
    private var objects: [DatabaseObject] = []
    private var selected: DatabaseObject? { sidebar.selectedRow >= 0 ? objects[sidebar.selectedRow] : nil }

    private enum Tab: Int { case data, structure, query }
    private var tab = Tab.data {
        didSet { showTab() }
    }

    // Paging through the selected table's rows.
    private let pageSize = 200
    private var offset = 0
    private var total = 0
    private var sort: (column: String, ascending: Bool)?
    private var rowIDs: [Int64] = []   // of the rows showing, when they can be edited

    private enum Keys {
        static let size = "menusqlite.size"
        static let pinned = "menusqlite.pinned"
        static let recent = "menusqlite.recent"
    }

    static let defaultSize = NSSize(width: 780, height: 540)
    static let minSize = NSSize(width: 600, height: 360)

    // MARK: Views

    private let titleLabel = NSTextField(labelWithString: "")
    private let sidebar = NSTableView()
    private let tabs = NSSegmentedControl()
    private let content = NSView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let dataGrid = Grid()
    private let queryGrid = Grid()
    private let structureView = NSTextView.scrollableTextView()
    private let editorView = NSTextView.scrollableTextView()
    private var editor: NSTextView { editorView.documentView as! NSTextView }
    private var structureText: NSTextView { structureView.documentView as! NSTextView }
    private let querySplit = NSSplitView()
    private var querySplitPlaced = false
    private let statusLabel = NSTextField(labelWithString: "")
    private var pinButton: NSButton!
    private var addRowButton: NSButton!
    private var deleteRowButton: NSButton!
    private var previousButton: NSButton!
    private var nextButton: NSButton!
    private var pageDivider: NSView!
    private var runButton: NSButton!
    private var localized: [(view: NSView, zh: String, en: String)] = []
    private var escapeMonitor: Any?
    private var sizeAtDragStart = NSSize.zero

    private var pinned = UserDefaults.standard.bool(forKey: Keys.pinned) {
        didSet {
            UserDefaults.standard.set(pinned, forKey: Keys.pinned)
            applyPopoverBehavior()
            updatePinButton()
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: savedSize))

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pinButton = toolButton("pin", "釘選：點其他地方時不關閉視窗（按 Esc 仍可隱藏）",
                               "Pin: keep the window open when clicking elsewhere (Esc still hides it)", #selector(togglePin(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let toolbar = NSStackView(views: [
            toolButton("folder", "開啟資料庫（⌘O）", "Open Database (⌘O)", #selector(openDocument(_:))),
            toolButton("clock.arrow.circlepath", "最近開啟的資料庫", "Recent Databases", #selector(showRecentMenu(_:))),
            toolButton("plus.rectangle.on.folder", "新增資料庫（⌘N）", "New Database (⌘N)", #selector(newDocument(_:))),
            divider(),
            toolButton("arrow.clockwise", "重新整理（⌘R）", "Refresh (⌘R)", #selector(refresh(_:))),
            toolButton("square.and.arrow.up", "匯出 CSV（⇧⌘E）", "Export CSV (⇧⌘E)", #selector(exportCSV(_:))),
            spacer,
            pinButton,
            toolButton("ellipsis.circle", "更多", "More", #selector(showMoreMenu(_:))),
        ])
        toolbar.spacing = 2
        let header = NSStackView(views: [titleLabel, toolbar])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 8)

        let body = NSSplitView()
        body.isVertical = true
        body.dividerStyle = .thin
        body.addArrangedSubview(makeSidebar())
        body.addArrangedSubview(makeDetail())
        body.setHoldingPriority(.init(260), forSubviewAt: 0)
        body.setHoldingPriority(.init(250), forSubviewAt: 1)

        let footer = makeFooter()
        let topLine = NSBox(), bottomLine = NSBox()
        topLine.boxType = .separator
        bottomLine.boxType = .separator
        let column = NSStackView(views: [header, topLine, body, bottomLine, footer])
        column.orientation = .vertical
        column.distribution = .fill   // fill the window top to bottom
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            toolbar.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -20),
            body.widthAnchor.constraint(equalTo: column.widthAnchor),
            footer.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        // The header and footer keep their own height; the tables and data take the rest. Split
        // views ask to keep their panes' sizes at priority 250, which would shrink everything to
        // its minimum, so the body reaches for all the height at a priority above that.
        header.setHuggingPriority(.required, for: .vertical)
        (footer as? NSStackView)?.setHuggingPriority(.required, for: .vertical)
        let fill = body.heightAnchor.constraint(equalToConstant: 10_000)
        fill.priority = .init(300)
        fill.isActive = true

        view = root
        preferredContentSize = root.frame.size
        NotificationCenter.default.addObserver(forName: Language.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyLanguage()
        }
        installEscapeMonitor()
        updatePinButton()
        applyLanguage()
        showTab()
        updateFooter()
        body.setPosition(190, ofDividerAt: 0)
    }

    private func makeSidebar() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("object"))
        column.resizingMask = .autoresizingMask
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 22
        sidebar.dataSource = self
        sidebar.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = sidebar
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return scroll
    }

    private func makeDetail() -> NSView {
        tabs.segmentStyle = .rounded
        tabs.segmentCount = 3
        tabs.trackingMode = .selectOne
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged(_:))

        // Data: the selected table's rows.
        dataGrid.onEdit = { [weak self] row, column, value in self?.edit(row: row, column: column, to: value) }
        dataGrid.onSort = { [weak self] column, ascending in
            self?.sort = (column, ascending)
            self?.offset = 0
            self?.loadPage()
        }
        dataGrid.extraMenuItems = { [weak self] in
            guard let self, self.dataGrid.editable, !self.dataGrid.tableView.selectedRowIndexes.isEmpty else { return [] }
            let item = NSMenuItem(title: tr("刪除選取的資料列…", "Delete Selected Rows…"), action: #selector(self.deleteRows(_:)), keyEquivalent: "")
            item.target = self
            return [item]
        }

        // Structure: columns, indexes and the CREATE statement.
        structureText.isEditable = false
        structureText.textContainerInset = NSSize(width: 10, height: 10)

        // Query: an SQL editor over its results.
        let sqlText = editor
        sqlText.delegate = self
        sqlText.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        sqlText.isRichText = false
        sqlText.allowsUndo = true
        sqlText.isAutomaticQuoteSubstitutionEnabled = false
        sqlText.isAutomaticDashSubstitutionEnabled = false
        sqlText.isAutomaticTextReplacementEnabled = false
        sqlText.isContinuousSpellCheckingEnabled = false
        sqlText.textContainerInset = NSSize(width: 6, height: 8)
        runButton = NSButton(title: "", target: self, action: #selector(runQuery(_:)))
        runButton.bezelStyle = .rounded
        runButton.keyEquivalent = "\r"
        runButton.keyEquivalentModifierMask = .command
        let runHint = NSTextField(labelWithString: "")
        runHint.textColor = .secondaryLabelColor
        runHint.font = .systemFont(ofSize: 11)
        localized.append((runHint, "執行選取的語句，沒有選取就執行全部", "Runs the selection, or everything if nothing is selected"))
        let runBar = NSStackView(views: [runButton, runHint, NSView()])
        runBar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        let editorPane = NSStackView(views: [editorView, runBar])
        editorPane.orientation = .vertical
        editorPane.spacing = 0
        editorView.widthAnchor.constraint(equalTo: editorPane.widthAnchor).isActive = true
        runBar.widthAnchor.constraint(equalTo: editorPane.widthAnchor).isActive = true
        querySplit.isVertical = false
        querySplit.dividerStyle = .thin
        querySplit.addArrangedSubview(editorPane)
        querySplit.addArrangedSubview(queryGrid.scrollView)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        for view in [dataGrid.scrollView, structureView, querySplit, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            let inset: CGFloat = view === emptyLabel ? 24 : 0
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
                view === emptyLabel ? view.centerYAnchor.constraint(equalTo: content.centerYAnchor)
                                    : view.topAnchor.constraint(equalTo: content.topAnchor),
            ])
            if view !== emptyLabel { view.bottomAnchor.constraint(equalTo: content.bottomAnchor).isActive = true }
        }

        let tabBar = NSStackView(views: [tabs])
        tabBar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        tabBar.setHuggingPriority(.required, for: .vertical)   // its own height; the content takes the rest
        let detail = NSStackView(views: [tabBar, content])
        detail.orientation = .vertical
        detail.distribution = .fill   // stretch the content; the default leaves it at its minimum
        detail.spacing = 0
        // A stack holds tight to its views by default, which would keep the whole pane at its smallest.
        detail.setHuggingPriority(.init(1), for: .vertical)
        content.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        content.setContentHuggingPriority(.init(1), for: .vertical)
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return detail
    }

    private func makeFooter() -> NSView {
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addRowButton = smallButton("plus", "新增一列", "Add a Row", #selector(addRow(_:)))
        deleteRowButton = smallButton("minus", "刪除選取的資料列", "Delete Selected Rows", #selector(deleteRows(_:)))
        previousButton = smallButton("chevron.left", "上一頁", "Previous Page", #selector(previousPage(_:)))
        nextButton = smallButton("chevron.right", "下一頁", "Next Page", #selector(nextPage(_:)))
        let grip = ResizeGrip()
        grip.onBegin = { [weak self] in self?.sizeAtDragStart = self?.view.frame.size ?? .zero }
        grip.onDrag = { [weak self] delta in
            guard let self else { return }
            // The popover stays centered under the menu bar icon, so its right edge moves half as
            // far as the width changes; doubling keeps the corner under the pointer.
            self.resize(to: NSSize(width: self.sizeAtDragStart.width + delta.width * 2,
                                   height: self.sizeAtDragStart.height + delta.height))
        }
        grip.onReset = { [weak self] in self?.resetSize(nil) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        pageDivider = divider()
        let footer = NSStackView(views: [statusLabel, spacer, addRowButton, deleteRowButton, pageDivider,
                                         previousButton, nextButton, grip])
        footer.spacing = 4
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 6, right: 12)
        return footer
    }

    private func toolButton(_ symbol: String, _ zh: String, _ en: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        localized.append((button, zh, en))
        return button
    }

    private func smallButton(_ symbol: String, _ zh: String, _ en: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))!
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        localized.append((button, zh, en))
        return button
    }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 9).isActive = true
        box.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return box
    }

    /// Relabels everything on screen; menus are built each time they open.
    private func applyLanguage() {
        for (view, zh, en) in localized {
            if let label = view as? NSTextField { label.stringValue = tr(zh, en) } else {
                view.toolTip = tr(zh, en)
                view.setAccessibilityLabel(view.toolTip)
            }
        }
        tabs.setLabel(tr("資料", "Data"), forSegment: 0)
        tabs.setLabel(tr("結構", "Structure"), forSegment: 1)
        tabs.setLabel("SQL", forSegment: 2)
        runButton.title = tr("執行 ⌘↩", "Run ⌘↩")
        updateTitle()
        updateFooter()
        showTab()
    }

    func focus() {
        view.window?.makeFirstResponder(tab == .query ? editor : database == nil ? nil : sidebar)
    }

    // MARK: - Opening

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.delegate = self   // only SQLite files can be chosen; see panel(_:shouldEnable:)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = tr("選擇 SQLite 資料庫檔案", "Choose an SQLite database file")
        guard keepingPopoverOpen({ panel.runModal() }) == .OK, let url = panel.url else { return }
        open(url)
    }

    /// SQLite files are told by their first bytes, since they go by many extensions or none.
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true { return values?.isPackage != true }
        return Database.isDatabaseFile(url)
    }

    @objc func newDocument(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tr("新資料庫.sqlite", "New Database.sqlite")
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        guard keepingPopoverOpen({ panel.runModal() }) == .OK, let url = panel.url else { return }
        do {
            // The panel already asked about replacing an existing file.
            try? FileManager.default.removeItem(at: url)
            show(try Database(url: url, create: true))
        } catch {
            showError(tr("無法建立「\(url.lastPathComponent)」", "Couldn’t create “\(url.lastPathComponent)”"), error)
        }
    }

    /// Opens a database: from the panel, the recent list, or a file handed over by Finder.
    func open(_ url: URL) {
        do {
            show(try Database(url: url))
        } catch {
            showError(tr("無法開啟「\(url.lastPathComponent)」", "Couldn’t open “\(url.lastPathComponent)”"), error)
            forgetRecent(url)
        }
    }

    private func show(_ database: Database) {
        _ = view   // reopening at launch comes before the window: the table list must exist
        self.database = database
        addRecent(database.url)
        sort = nil
        offset = 0
        reloadObjects()
        if editor.string.isEmpty, let first = objects.first {
            editor.string = "SELECT * FROM \(Database.quote(first.name)) LIMIT 100;"
            highlightSQL()
        }
        queryGrid.show(ResultSet())
        updateTitle()
        focus()
    }

    /// Reopens the database used last, so the window comes back as it was left.
    func reopenLast() {
        guard let path = recent.first, FileManager.default.fileExists(atPath: path) else { return }
        if let database = try? Database(url: URL(fileURLWithPath: path)) { show(database) }
    }

    private func updateTitle() {
        guard let database else {
            titleLabel.stringValue = tr("尚未開啟資料庫", "No Database Open")
            titleLabel.toolTip = nil
            return
        }
        titleLabel.stringValue = database.url.lastPathComponent + (database.readOnly ? tr("（唯讀）", " (Read-Only)") : "")
        titleLabel.toolTip = database.url.path
    }

    // MARK: Recent databases

    private var recent: [String] {
        get { UserDefaults.standard.stringArray(forKey: Keys.recent) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(10)), forKey: Keys.recent) }
    }

    private func addRecent(_ url: URL) {
        recent = [url.path] + recent.filter { $0 != url.path }
    }

    private func forgetRecent(_ url: URL) {
        recent = recent.filter { $0 != url.path }
    }

    @objc func showRecentMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for path in recent {
            let item = NSMenuItem(title: (path as NSString).lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.toolTip = path
            item.representedObject = path
            item.target = self
            item.image = NSImage(systemSymbolName: "cylinder", accessibilityDescription: nil)
            menu.addItem(item)
        }
        if recent.isEmpty {
            let none = NSMenuItem(title: tr("沒有最近開啟的資料庫", "No Recent Databases"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: tr("清除清單", "Clear List"), action: #selector(clearRecent(_:)), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        open(URL(fileURLWithPath: path))
    }

    @objc private func clearRecent(_ sender: Any?) {
        recent = []
    }

    // MARK: - Tables

    /// Reads the list of tables and views again, keeping the selection where it still exists.
    private func reloadObjects() {
        let previous = selected
        objects = (try? database?.objects()) ?? []
        sidebar.reloadData()
        let index = previous.flatMap(objects.firstIndex(of:)) ?? (objects.isEmpty ? nil : 0)
        if let index {
            sidebar.selectRowIndexes([index], byExtendingSelection: false)
            sidebar.scrollRowToVisible(index)
        }
        if index == nil || objects[index!] != previous { selectionChanged() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { objects.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("object")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView(), text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            for view in [image, text] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.imageView = image
            cell.textField = text
            return cell
        }()
        let object = objects[row]
        cell.textField?.stringValue = object.name
        cell.imageView?.image = NSImage(systemSymbolName: object.kind == .table ? "tablecells" : "eye",
                                        accessibilityDescription: object.kind == .table ? tr("資料表", "Table") : tr("視圖", "View"))
        cell.toolTip = object.kind == .view ? tr("視圖（唯讀）", "View (read-only)") : nil
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as AnyObject === sidebar else { return }
        selectionChanged()
    }

    private func selectionChanged() {
        sort = nil
        offset = 0
        loadPage()
        loadStructure()
        showTab()
    }

    // MARK: - Data tab

    /// Shows the current page of the selected table's rows.
    private func loadPage() {
        guard let database, let object = selected else {
            dataGrid.show(ResultSet())
            rowIDs = []
            total = 0
            updateFooter()
            return
        }
        do {
            let editable = !database.readOnly && database.hasRowID(object)
            total = try database.rowCount(of: object.name)
            if offset >= total, total > 0 { offset = (total - 1) / pageSize * pageSize }
            var page = try database.rows(of: object, orderBy: sort?.column, ascending: sort?.ascending ?? true,
                                         limit: pageSize, offset: offset, rowIDs: editable)
            if editable {
                // The rowid came first, to find each row again when it's edited; it isn't shown.
                rowIDs = page.rows.map { if case .integer(let id) = $0[0] { return id }; return 0 }
                page.columns.removeFirst()
                page.rows = page.rows.map { Array($0.dropFirst()) }
            } else {
                rowIDs = []
            }
            dataGrid.editable = editable
            dataGrid.show(page, sortedBy: sort)
            updateFooter()
        } catch {
            dataGrid.show(ResultSet())
            showStatus(error.localizedDescription, error: true)
        }
    }

    private func edit(row: Int, column: Int, to value: Value) {
        guard let database, let table = selected?.name, rowIDs.indices.contains(row) else { return }
        do {
            try database.update(table, column: dataGrid.result.columns[column], to: value, rowID: rowIDs[row])
            let selection = dataGrid.tableView.selectedRowIndexes
            loadPage()
            dataGrid.tableView.selectRowIndexes(selection, byExtendingSelection: false)
        } catch {
            showError(tr("無法修改", "Couldn’t change the value"), error)
        }
    }

    @objc func addRow(_ sender: Any?) {
        guard let database, let table = selected?.name, dataGrid.editable else { return NSSound.beep() }
        do {
            let id = try database.insertRow(into: table)
            // New rows go last unless sorted otherwise; show the page that has it.
            sort = nil
            total += 1
            offset = (total - 1) / pageSize * pageSize
            loadPage()
            if let row = rowIDs.firstIndex(of: id) {
                dataGrid.tableView.selectRowIndexes([row], byExtendingSelection: false)
                dataGrid.tableView.scrollRowToVisible(row)
            }
        } catch {
            showError(tr("無法新增資料列", "Couldn’t add a row"), error,
                      hint: tr("有不允許空值又沒有預設值的欄位時，請改用 SQL 的 INSERT 指定欄位值。",
                               "When a column can't be NULL and has no default, use an SQL INSERT that gives its value."))
        }
    }

    @objc func deleteRows(_ sender: Any?) {
        let rows = dataGrid.tableView.selectedRowIndexes
        guard let database, let table = selected?.name, dataGrid.editable, !rows.isEmpty else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = tr("要刪除 \(rows.count) 列資料嗎？", "Delete \(rows.count) row\(rows.count == 1 ? "" : "s")?")
        alert.informativeText = tr("刪除後無法復原。", "This can’t be undone.")
        alert.addButton(withTitle: tr("刪除", "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("取消", "Cancel"))
        guard keepingPopoverOpen({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        do {
            try database.deleteRows(from: table, rowIDs: rows.compactMap { rowIDs.indices.contains($0) ? rowIDs[$0] : nil })
            loadPage()
        } catch {
            showError(tr("無法刪除", "Couldn’t delete"), error)
        }
    }

    @objc func previousPage(_ sender: Any?) {
        guard offset > 0 else { return }
        offset = max(0, offset - pageSize)
        loadPage()
    }

    @objc func nextPage(_ sender: Any?) {
        guard offset + pageSize < total else { return }
        offset += pageSize
        loadPage()
    }

    // MARK: - Structure tab

    private func loadStructure() {
        let text = NSMutableAttributedString()
        guard let database, let object = selected else {
            structureText.textStorage?.setAttributedString(text)
            return
        }
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                   .foregroundColor: NSColor.labelColor]
        func heading(_ title: String) {
            if text.length > 0 { text.append(NSAttributedString(string: "\n", attributes: body)) }
            text.append(NSAttributedString(string: title + "\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
        }
        func line(_ s: String, color: NSColor = .labelColor) {
            var attrs = body
            attrs[.foregroundColor] = color
            text.append(NSAttributedString(string: s + "\n", attributes: attrs))
        }
        do {
            let columns = try database.columns(of: object.name)
            heading(tr("欄位", "Columns"))
            let rows = [[tr("名稱", "Name"), tr("類型", "Type"), tr("非空", "Not Null"), tr("預設值", "Default"), tr("主鍵", "Key")]]
                + columns.map { [$0.name, $0.type, $0.notNull ? "✓" : "", $0.defaultValue ?? "", $0.primaryKey > 0 ? "\($0.primaryKey)" : ""] }
            // Tab stops at each column's widest text keep the columns lined up, Chinese included.
            let font = body[.font] as! NSFont
            var stop: CGFloat = 0
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = (0..<4).map { i in
                stop += (rows.map { ($0[i] as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + 16
                return NSTextTab(textAlignment: .left, location: stop)
            }
            for (n, row) in rows.enumerated() {
                text.append(NSAttributedString(string: row.joined(separator: "\t") + "\n", attributes: [
                    .font: font, .paragraphStyle: paragraph,
                    .foregroundColor: n == 0 ? NSColor.secondaryLabelColor : NSColor.labelColor]))
            }
            if object.kind == .table {
                let indexes = try database.indexes(of: object.name)
                heading(tr("索引", "Indexes"))
                if indexes.isEmpty { line(tr("（沒有）", "(none)"), color: .secondaryLabelColor) }
                for index in indexes {
                    line("\(index.name)\(index.unique ? " UNIQUE" : "")  (\(index.columns.joined(separator: ", ")))")
                }
                heading(tr("資料列", "Rows"))
                line(String(try database.rowCount(of: object.name)))
            }
            if let sql = try database.createStatement(of: object.name) {
                heading(tr("建立語句", "CREATE Statement"))
                let statement = NSMutableAttributedString(string: sql + "\n", attributes: body)
                SyntaxHighlighter.highlight(statement, language: "sql")
                text.append(statement)
            }
        } catch {
            line(error.localizedDescription, color: .systemRed)
        }
        structureText.textStorage?.setAttributedString(text)
    }

    // MARK: - SQL tab

    @objc func runQuery(_ sender: Any?) {
        guard let database else { return NSSound.beep() }
        tab = .query
        let selection = editor.selectedRange()
        let sql = selection.length > 0 ? (editor.string as NSString).substring(with: selection) : editor.string
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return NSSound.beep() }
        let start = Date()
        do {
            let result = try database.run(sql)
            let time = String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)
            queryGrid.show(result)
            if result.columns.isEmpty {
                showStatus(tr("已執行，影響 \(result.changes) 列 · \(time)", "Done, \(result.changes) rows changed · \(time)"))
            } else {
                showStatus(tr("\(result.rows.count) 列 · \(time)", "\(result.rows.count) rows · \(time)")
                           + (result.changes > 0 ? tr("，影響 \(result.changes) 列", ", \(result.changes) changed") : ""))
            }
        } catch {
            showStatus(error.localizedDescription, error: true)
        }
        // A statement may have changed tables, or the rows of the one selected.
        reloadObjects()
        loadPage()
        loadStructure()
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject === editor else { return }
        highlightSQL()
    }

    private func highlightSQL() {
        guard let storage = editor.textStorage else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: storage.length))
        SyntaxHighlighter.highlight(storage, language: "sql")
        storage.endEditing()
    }

    // MARK: - Tabs and status

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        tab = Tab(rawValue: sender.selectedSegment) ?? .data
    }

    @objc func showDataTab(_ sender: Any?) { tab = .data }
    @objc func showStructureTab(_ sender: Any?) { tab = .structure }
    @objc func showQueryTab(_ sender: Any?) { tab = .query }

    private func showTab() {
        guard isViewLoaded else { return }
        tabs.selectedSegment = tab.rawValue
        let hasTable = selected != nil
        dataGrid.scrollView.isHidden = tab != .data || !hasTable
        structureView.isHidden = tab != .structure || !hasTable
        querySplit.isHidden = tab != .query || database == nil
        emptyLabel.isHidden = !(dataGrid.scrollView.isHidden && structureView.isHidden && querySplit.isHidden)
        emptyLabel.stringValue = database == nil
            ? tr("按工具列的資料夾按鈕開啟 SQLite 資料庫（⌘O），或按 ⌘N 新增一個。",
                 "Open an SQLite database with the folder button (⌘O), or make a new one with ⌘N.")
            : objects.isEmpty
            ? tr("這個資料庫還沒有資料表。到「SQL」分頁用 CREATE TABLE 建立。",
                 "This database has no tables yet. Make one with CREATE TABLE in the SQL tab.")
            : tr("從左邊選一個資料表。", "Choose a table on the left.")
        if tab == .query, !querySplitPlaced {
            // Once it first has a size: the editor gets the top 40%, the results the rest.
            view.layoutSubtreeIfNeeded()
            if querySplit.frame.height > 0 {
                querySplit.setPosition(max(120, querySplit.frame.height * 0.4), ofDividerAt: 0)
                querySplitPlaced = true
            }
        }
        updateFooter()
    }

    /// The status line shows the page of rows, or a message such as a query's result or an error.
    private var message: (text: String, error: Bool)?

    private func showStatus(_ text: String, error: Bool = false) {
        message = (text, error)
        updateFooter()
    }

    private func updateFooter() {
        guard isViewLoaded else { return }
        let paging = tab == .data && selected != nil
        for view in [previousButton, nextButton, pageDivider] { view?.isHidden = !paging }
        addRowButton.isHidden = !paging || !dataGrid.editable
        deleteRowButton.isHidden = addRowButton.isHidden
        previousButton.isEnabled = offset > 0
        nextButton.isEnabled = offset + pageSize < total
        if tab == .query, let message {
            statusLabel.stringValue = message.text
            statusLabel.textColor = message.error ? .systemRed : .secondaryLabelColor
        } else if paging {
            let shown = dataGrid.result.rows.count
            statusLabel.stringValue = total == 0 ? tr("沒有資料", "No rows")
                : tr("第 \(offset + 1)–\(offset + shown) 列，共 \(total) 列", "Rows \(offset + 1)–\(offset + shown) of \(total)")
                    + (dataGrid.editable || selected?.kind == .view ? "" : tr("（唯讀）", " (read-only)"))
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = ""
        }
    }

    // MARK: - Refresh and export

    @objc func refresh(_ sender: Any?) {
        reloadObjects()
        loadPage()
        loadStructure()
    }

    /// Exports the query's results on the SQL tab, or the whole selected table otherwise.
    @objc func exportCSV(_ sender: Any?) {
        guard let database else { return NSSound.beep() }
        let result: ResultSet
        let name: String
        do {
            if tab == .query {
                result = queryGrid.result
                name = tr("查詢結果", "Query Results")
            } else if let object = selected {
                result = try database.run("SELECT * FROM \(Database.quote(object.name))")
                name = object.name
            } else {
                return NSSound.beep()
            }
        } catch {
            return showError(tr("無法匯出", "Couldn’t export"), error)
        }
        guard !result.columns.isEmpty else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + ".csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard keepingPopoverOpen({ panel.runModal() }) == .OK, let url = panel.url else { return }
        do {
            try CSV.data(result).write(to: url, options: .atomic)
        } catch {
            showError(tr("無法匯出", "Couldn’t export"), error)
        }
    }

    // MARK: - Popover

    private var savedSize: NSSize {
        get { UserDefaults.standard.string(forKey: Keys.size).map { clamp(NSSizeFromString($0)) } ?? Self.defaultSize }
        set { UserDefaults.standard.set(NSStringFromSize(newValue), forKey: Keys.size) }
    }

    private func clamp(_ size: NSSize) -> NSSize {
        let screen = (isViewLoaded ? view.window?.screen : nil)?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size
            ?? NSSize(width: 1440, height: 900)
        return NSSize(width: min(max(size.width, Self.minSize.width), screen.width - 40),
                      height: min(max(size.height, Self.minSize.height), screen.height - 30))
    }

    private func resize(to size: NSSize) {
        let size = clamp(size)
        preferredContentSize = size
        popover?.contentSize = size
        savedSize = size
        view.window?.invalidateCursorRects(for: view)
    }

    @objc func resetSize(_ sender: Any?) {
        resize(to: Self.defaultSize)
    }

    func applyPopoverBehavior() {
        popover?.behavior = pinned ? .applicationDefined : .transient
    }

    private func updatePinButton() {
        pinButton?.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        pinButton?.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
    }

    @objc func togglePin(_ sender: Any?) {
        pinned.toggle()
    }

    @objc func closePopover(_ sender: Any?) {
        popover?.performClose(sender)
    }

    /// Esc hides the window, except while editing text, where it ends the edit.
    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, let window = self.view.window, event.window === window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty,
                  !(window.firstResponder is NSText) || window.firstResponder === self.editor else { return event }
            self.closePopover(nil)
            return nil
        }
    }

    /// Keeps the popover open, and below them, while a panel or alert is up.
    private func keepingPopoverOpen<T>(_ body: () -> T) -> T {
        popover?.behavior = .applicationDefined
        NSApp.activate(ignoringOtherApps: true)
        let window = view.window, level = window?.level
        window?.level = .normal
        defer {
            if let level { window?.level = level }
            applyPopoverBehavior()
            window?.makeKey()
        }
        return body()
    }

    private func showError(_ title: String, _ error: Error, hint: String? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = [error.localizedDescription, hint].compactMap { $0 }.joined(separator: "\n\n")
        keepingPopoverOpen { _ = alert.runModal() }
    }

    // MARK: - More menu

    @objc func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()
        add(menu, tr("開啟資料庫…", "Open Database…"), #selector(openDocument(_:)), key: "o")
        add(menu, tr("新增資料庫…", "New Database…"), #selector(newDocument(_:)), key: "n")
        add(menu, tr("匯出 CSV…", "Export CSV…"), #selector(exportCSV(_:)), key: "E")
        menu.addItem(.separator())
        add(menu, tr("恢復預設視窗大小", "Restore Default Window Size"), #selector(resetSize(_:)))
        let themes = NSMenu()
        for theme in Theme.allCases {
            let item = add(themes, theme.title, #selector(selectTheme(_:)))
            item.representedObject = theme.rawValue
            item.state = theme == Theme.current ? .on : .off
        }
        menu.addItem(withTitle: tr("主題", "Theme"), action: nil, keyEquivalent: "").submenu = themes
        let languages = NSMenu()
        for language in Language.allCases {
            let item = add(languages, language.title, #selector(selectLanguage(_:)))
            item.representedObject = language.rawValue
            item.state = language == Language.current ? .on : .off
        }
        menu.addItem(withTitle: tr("語言", "Language"), action: nil, keyEquivalent: "").submenu = languages
        menu.addItem(.separator())
        add(menu, tr("登入時自動開啟", "Open at Login"), #selector(toggleLaunchAtLogin(_:))).state =
            SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        add(menu, tr("關於隨手庫", "About MenuSQLite"), #selector(showAbout(_:)))
        menu.addItem(withTitle: tr("結束隨手庫", "Quit MenuSQLite"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = Theme(rawValue: raw) else { return }
        Theme.current = theme
        Theme.apply(to: popover)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = Language(rawValue: raw) else { return }
        Language.current = language
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            showError(tr("無法變更「登入時自動開啟」", "Couldn’t change “Open at Login”"), error)
        }
    }

    @objc private func showAbout(_ sender: Any?) {
        closePopover(nil)
        NSApp.activate(ignoringOtherApps: true)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(string: "Created by : Jeff Lee", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: tr("隨手庫", "MenuSQLite"), .credits: credits])
    }
}

extension MainViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(refresh(_:)), #selector(exportCSV(_:)), #selector(runQuery(_:)), #selector(showQueryTab(_:)):
            return database != nil
        case #selector(showDataTab(_:)), #selector(showStructureTab(_:)):
            return selected != nil
        case #selector(addRow(_:)):
            return dataGrid.editable && tab == .data
        default:
            return true
        }
    }
}
