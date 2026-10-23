import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/// The popover's content: the open database's tables on the left, and on the right a table's
/// rows, its structure, or an SQL query and its results.
final class MainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                NSTextViewDelegate, NSOpenSavePanelDelegate {
    weak var popover: NSPopover?
    /// The window the content moves to while pinned, which can be dragged anywhere.
    weak var pinnedWindow: NSWindow?
    /// Called when the pin is switched on or off, to move the content between popover and window.
    var onPinChange: ((Bool) -> Void)?
    private var inPinnedWindow: Bool { pinnedWindow != nil && view.window === pinnedWindow }

    private(set) var database: DatabaseConnection?
    private var objects: [DatabaseObject] = []
    private var selected: DatabaseObject? { sidebar.selectedRow >= 0 ? objects[sidebar.selectedRow] : nil }
    /// The table the Data and Structure tabs were last loaded for. Reloading the table list
    /// reselects the same row, which mustn't count as choosing it again and lose its filter.
    private var shown: DatabaseObject?

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
    /// The SELECT the SQL tab was last given to match the Data tab, and the last one of those run.
    /// Once someone edits it, it's theirs and stays as they left it.
    private var matchingSQL: String?
    private var ranMatchingSQL: String?

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
    private let filterBar = FilterBar()
    private var dataPane: NSStackView!
    private var filterButton: NSButton!
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
    private var newTableButton: NSButton!
    private var editTableButton: NSButton!
    private var deleteTableButton: NSButton!
    private var importButton: NSButton!
    /// Toolbar buttons that act on the open database: Refresh, Export, Info, Structure Document.
    private var databaseButtons: [NSButton] = []
    private var runButton: NSButton!
    private var localized: [(view: NSView, zh: String, en: String)] = []
    private var escapeMonitor: Any?
    private var sizeAtDragStart = NSSize.zero

    /// False while there's no menu bar icon for the popover to hang from, so the window stays pinned.
    var canUnpin = true

    var pinned = UserDefaults.standard.bool(forKey: Keys.pinned) {
        didSet {
            UserDefaults.standard.set(pinned, forKey: Keys.pinned)
            applyPopoverBehavior()
            updatePinButton()
            onPinChange?(pinned)
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: savedSize))

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pinButton = toolButton("pin", "釘選：視窗固定顯示，可拖曳上緣或空白處移動（按 Esc 仍可隱藏）；解除後回到選單列下方原本的大小",
                               "Pin: keep the window open and drag it anywhere by its top edge (Esc still hides it); unpinning puts it back under the menu bar at its earlier size",
                               #selector(togglePin(_:)))
        importButton = toolButton("square.and.arrow.down", "匯入 CSV 到選取的資料表（⇧⌘I）", "Import CSV into the Selected Table (⇧⌘I)",
                                  #selector(importCSV(_:)))
        databaseButtons = [
            toolButton("arrow.clockwise", "重新整理（⌘R）", "Refresh (⌘R)", #selector(refresh(_:))),
            toolButton("square.and.arrow.up", "匯出 CSV（⇧⌘E）", "Export CSV (⇧⌘E)", #selector(exportCSV(_:))),
            toolButton("info.circle", "資料庫資訊：位置、大小、壓縮（⌘I）", "Database Info: location, size, compacting (⌘I)",
                       #selector(showDatabaseInfo(_:))),
            toolButton("doc.richtext", "結構文件：所有資料表和視圖的結構（Markdown，⇧⌘D）",
                       "Structure Document: every table and view, as Markdown (⇧⌘D)", #selector(showSchemaDocument(_:))),
        ]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let toolbar = NSStackView(views: [
            toolButton("folder", "開啟資料庫（⌘O）", "Open Database (⌘O)", #selector(openDocument(_:))),
            toolButton("clock.arrow.circlepath", "最近開啟的資料庫", "Recent Databases", #selector(showRecentMenu(_:))),
            toolButton("plus.rectangle.on.folder", "新增資料庫（⌘N）", "New Database (⌘N)", #selector(newDocument(_:))),
            toolButton("network", "透過 SSH 連線到伺服器上的資料庫（⇧⌘O）",
                       "Open a Database on a Server over SSH (⇧⌘O)", #selector(connectRemote(_:))),
            divider(),
            databaseButtons[0],
            importButton,
            databaseButtons[1],
            databaseButtons[2],
            databaseButtons[3],
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
        updateTableButtons()   // nothing open yet: the database's buttons start off
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

        // Right-click a table, or use the buttons under the list, to add, change or delete tables.
        let menu = NSMenu()
        for (zh, en, action) in [("新增資料表…", "New Table…", #selector(newTable(_:))),
                                 ("新增視圖…", "New View…", #selector(newView(_:))),
                                 ("編輯…", "Edit…", #selector(editTable(_:))),
                                 ("匯入 CSV…", "Import CSV…", #selector(importCSV(_:))),
                                 ("刪除…", "Delete…", #selector(deleteTable(_:)))] {
            let item = menu.addItem(withTitle: tr(zh, en), action: action, keyEquivalent: "")
            item.target = self
        }
        sidebar.menu = menu
        newTableButton = smallButton("plus", "新增資料表或視圖", "New Table or View", #selector(showNewMenu(_:)))
        editTableButton = smallButton("pencil", "編輯資料表或視圖（⌥⌘E）", "Edit Table or View (⌥⌘E)", #selector(editTable(_:)))
        deleteTableButton = smallButton("trash", "刪除資料表", "Delete Table", #selector(deleteTable(_:)))
        let bar = NSStackView(views: [newTableButton, editTableButton, deleteTableButton, NSView()])
        bar.spacing = 2
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        let pane = NSStackView(views: [scroll, bar])
        pane.orientation = .vertical
        pane.distribution = .fill
        pane.spacing = 0
        pane.setHuggingPriority(.init(1), for: .vertical)
        bar.setHuggingPriority(.required, for: .vertical)
        scroll.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true
        return pane
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
            self?.matchQueryToData()
        }
        dataGrid.extraMenuItems = { [weak self] in
            guard let self, self.dataGrid.editable, !self.dataGrid.tableView.selectedRowIndexes.isEmpty else { return [] }
            let item = NSMenuItem(title: tr("刪除選取的資料列…", "Delete Selected Rows…"), action: #selector(self.deleteRows(_:)), keyEquivalent: "")
            item.target = self
            return [item]
        }

        filterBar.onChange = { [weak self] in
            self?.offset = 0
            self?.loadPage()
            self?.updateFilterButton()
            self?.matchQueryToData()
        }
        dataPane = NSStackView(views: [filterBar, dataGrid.scrollView])
        dataPane.orientation = .vertical
        dataPane.distribution = .fill
        dataPane.spacing = 0
        filterBar.widthAnchor.constraint(equalTo: dataPane.widthAnchor).isActive = true
        dataGrid.scrollView.widthAnchor.constraint(equalTo: dataPane.widthAnchor).isActive = true
        filterBar.setHuggingPriority(.required, for: .vertical)
        dataGrid.scrollView.setContentHuggingPriority(.init(1), for: .vertical)

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
        for view in [dataPane!, structureView, querySplit, emptyLabel] {
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

        filterButton = toolButton("line.3.horizontal.decrease.circle", "篩選資料列（⌥⌘F）", "Filter Rows (⌥⌘F)",
                                  #selector(toggleFilter(_:)))
        let tabSpacer = NSView()
        tabSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let tabBar = NSStackView(views: [tabs, tabSpacer, filterButton])
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
            // far as the width changes; doubling keeps the corner under the pointer. The pinned
            // window keeps its left edge, so there the corner follows the pointer as it is.
            let factor: CGFloat = self.inPinnedWindow ? 1 : 2
            self.resize(to: NSSize(width: self.sizeAtDragStart.width + delta.width * factor,
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
        filterBar.applyLanguage()
        // The structure text carries its headings in the language it was built in.
        loadStructure()
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
            forgetRecent(url.path)
        }
    }

    private func show(_ database: DatabaseConnection) {
        _ = view   // reopening at launch comes before the window: the table list must exist
        self.database = database
        shown = nil   // a table of the same name in another database is another table
        addRecent(database.recentKey)
        sort = nil
        offset = 0
        reloadObjects()
        queryGrid.show(ResultSet())
        ranMatchingSQL = nil
        matchQueryToData()
        updateTitle()
        focus()
    }

    /// Reopens the database used last, so the window comes back as it was left. Not one on a
    /// server: an unreachable one would hold up the launch.
    func reopenLast() {
        guard let path = recent.first, RemoteLocation(key: path) == nil, FileManager.default.fileExists(atPath: path) else { return }
        if let database = try? Database(url: URL(fileURLWithPath: path)) { show(database) }
    }

    // MARK: Databases on servers

    /// Asks where the database is: the server, its SSH port and key, and the file's path there.
    /// The server can be picked from ~/.ssh/config, which fills in the rest.
    @objc func connectRemote(_ sender: Any?) {
        let remotes = recent.compactMap(RemoteLocation.init(key:))
        let form = RemoteForm(start: remotes.first) { alias in remotes.first { $0.destination == alias }?.path }
        let alert = NSAlert()
        alert.messageText = tr("連線到伺服器上的 SQLite 資料庫", "Open an SQLite Database on a Server")
        alert.informativeText = tr("透過 SSH 在伺服器上執行 sqlite3，直接讀寫那個檔案。用 SSH 金鑰或 ssh-agent 登入，伺服器需要裝有 sqlite3。",
                                   "Runs sqlite3 on the server over SSH, working on the file where it is. Signs in with SSH keys or ssh-agent; the server needs sqlite3.")
        alert.accessoryView = form.view
        alert.addButton(withTitle: tr("連線", "Connect"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.window.initialFirstResponder = form.firstField
        guard keepingPopoverOpen({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        guard let location = form.location else { return NSSound.beep() }
        open(location)
    }

    /// Opens a database on a server: from the form, or the recent list.
    func open(_ location: RemoteLocation) {
        titleLabel.stringValue = tr("正在連線到 \(location.destination)…", "Connecting to \(location.destination)…")
        titleLabel.display()
        do {
            show(try RemoteDatabase(location))
        } catch {
            updateTitle()
            showError(tr("無法連線到「\(location.destination)」上的資料庫", "Couldn’t open the database on “\(location.destination)”"), error)
        }
    }

    private func updateTitle() {
        guard let database else {
            titleLabel.stringValue = tr("尚未開啟資料庫", "No Database Open")
            titleLabel.toolTip = nil
            return
        }
        let server = (database as? RemoteDatabase).map { " — " + $0.remote.destination } ?? ""
        titleLabel.stringValue = database.name + server + (database.readOnly ? tr("（唯讀）", " (Read-Only)") : "")
        titleLabel.toolTip = database.location
    }

    // MARK: Recent databases

    private var recent: [String] {
        get { UserDefaults.standard.stringArray(forKey: Keys.recent) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(10)), forKey: Keys.recent) }
    }

    /// Paths for files on this Mac, and RemoteLocation keys for ones on servers.
    private func addRecent(_ key: String) {
        recent = [key] + recent.filter { $0 != key }
    }

    private func forgetRecent(_ key: String) {
        recent = recent.filter { $0 != key }
    }

    @objc func showRecentMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for key in recent {
            let remote = RemoteLocation(key: key)
            let file = ((remote?.path ?? key) as NSString).lastPathComponent
            let item = NSMenuItem(title: remote.map { "\($0.destination)：\(file)" } ?? file,
                                  action: #selector(openRecent(_:)), keyEquivalent: "")
            item.toolTip = remote.map { "\($0.destination):\($0.path)" } ?? key
            item.representedObject = key
            item.target = self
            item.image = NSImage(systemSymbolName: remote == nil ? "cylinder" : "network", accessibilityDescription: nil)
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
        guard let key = sender.representedObject as? String else { return }
        if let remote = RemoteLocation(key: key) { open(remote) } else { open(URL(fileURLWithPath: key)) }
    }

    @objc private func clearRecent(_ sender: Any?) {
        recent = []
    }

    // MARK: - Tables

    private func updateTableButtons() {
        newTableButton?.isEnabled = canChangeSchema
        editTableButton?.isEnabled = canChangeSchema && selected != nil
        deleteTableButton?.isEnabled = canChangeSchema && selected != nil
        for button in databaseButtons { button.isEnabled = database != nil }
        // Rows can only be imported into a table, not a view.
        importButton?.isEnabled = canChangeSchema && selected?.kind == .table
    }

    /// Reads the list of tables and views again, keeping the selection where it still exists.
    private func reloadObjects() {
        defer { updateTableButtons() }
        let previous = selected
        objects = (try? database?.objects()) ?? []
        sidebar.reloadData()
        let index = previous.flatMap(objects.firstIndex(of:)) ?? (objects.isEmpty ? nil : 0)
        if let index {
            sidebar.selectRowIndexes([index], byExtendingSelection: false)
            sidebar.scrollRowToVisible(index)
        }
        if index == nil || selected != shown { selectionChanged() }
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
        guard notification.object as AnyObject === sidebar, selected != shown else { return }
        selectionChanged()
    }

    private func selectionChanged() {
        shown = selected
        updateTableButtons()
        sort = nil
        offset = 0
        filterBar.reset(columns: selectedColumns)
        updateFilterButton()
        matchQueryToData()
        loadPage()
        loadStructure()
        showTab()
    }

    // MARK: - Designing tables

    /// The table a right-click was on, or else the one selected.
    private var actedOn: DatabaseObject? {
        let row = sidebar.clickedRow >= 0 ? sidebar.clickedRow : sidebar.selectedRow
        return objects.indices.contains(row) ? objects[row] : nil
    }

    private var canChangeSchema: Bool { database.map { !$0.readOnly } ?? false }

    @objc func newTable(_ sender: Any?) {
        guard canChangeSchema else { return NSSound.beep() }
        let editor = TableEditor(snapshot: nil)
        guard keepingPopoverOpen({ editor.run() }), let sql = editor.sql else { return }
        changeSchema(sql, thenSelect: editor.tableName)
    }

    @objc private func showNewMenu(_ sender: NSButton) {
        let menu = NSMenu()
        add(menu, tr("新增資料表…", "New Table…"), #selector(newTable(_:)))
        add(menu, tr("新增視圖…", "New View…"), #selector(newView(_:)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func newView(_ sender: Any?) {
        guard canChangeSchema, let database else { return NSSound.beep() }
        editView(nil, in: database)
    }

    private func editView(_ name: String?, in database: DatabaseConnection) {
        let editor: ViewEditor
        do {
            editor = try ViewEditor(database: database, original: name)
        } catch {
            return showError(tr("無法讀取視圖的定義", "Couldn’t read the view’s definition"), error)
        }
        guard keepingPopoverOpen({ editor.run() }), let sql = editor.sql else { return }
        changeSchema(sql, thenSelect: editor.viewName)
    }

    /// Edits the table or view: columns for a table, the SELECT for a view.
    @objc func editTable(_ sender: Any?) {
        guard canChangeSchema, let database, let object = actedOn else { return NSSound.beep() }
        if object.kind == .view { return editView(object.name, in: database) }
        let snapshot: TableSnapshot
        do {
            snapshot = try TableDesign.snapshot(of: object.name, in: database)
        } catch {
            return showError(tr("無法讀取資料表結構", "Couldn’t read the table’s structure"), error)
        }
        let editor = TableEditor(snapshot: snapshot)
        guard keepingPopoverOpen({ editor.run() }), let sql = editor.sql else { return }
        changeSchema(sql, thenSelect: editor.tableName)
    }

    @objc func deleteTable(_ sender: Any?) {
        guard canChangeSchema, let database, let object = actedOn else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = object.kind == .table ? tr("要刪除資料表「\(object.name)」嗎？", "Delete the table “\(object.name)”?")
                                                  : tr("要刪除視圖「\(object.name)」嗎？", "Delete the view “\(object.name)”?")
        alert.informativeText = object.kind == .table ? tr("資料表和其中的資料都會刪除，無法復原。", "The table and all its rows will be deleted. This can’t be undone.")
                                                      : tr("只刪除視圖，不影響資料。", "Only the view goes; no data is deleted.")
        alert.addButton(withTitle: tr("刪除", "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("取消", "Cancel"))
        guard keepingPopoverOpen({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        do {
            try database.run("DROP \(object.kind == .table ? "TABLE" : "VIEW") \(Database.quote(object.name))")
            reloadObjects()
        } catch {
            showError(tr("無法刪除", "Couldn’t delete"), error)
        }
    }

    private func changeSchema(_ sql: String, thenSelect name: String) {
        guard let database else { return }
        do {
            try TableDesign.apply(sql, to: database)
        } catch {
            showError(tr("無法變更資料表", "Couldn’t change the table"), error)
        }
        reloadObjects()
        if let row = objects.firstIndex(where: { $0.name == name }) {
            sidebar.selectRowIndexes([row], byExtendingSelection: false)
            sidebar.scrollRowToVisible(row)
        }
        refresh(nil)
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
            let filter = filterBar.condition
            total = try database.rowCount(of: object.name, filter: filter)
            if offset >= total, total > 0 { offset = (total - 1) / pageSize * pageSize }
            var page = try database.rows(of: object, filter: filter, orderBy: sort?.column, ascending: sort?.ascending ?? true,
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

    /// The selected table's columns, for the filter to choose from.
    private var selectedColumns: [Column] {
        guard let database, let object = selected else { return [] }
        return (try? database.columns(of: object.name)) ?? []
    }

    @objc func toggleFilter(_ sender: Any?) {
        guard selected != nil else { return NSSound.beep() }
        tab = .data
        filterBar.toggle()
        updateFilterButton()
    }

    private func updateFilterButton() {
        filterButton.contentTintColor = filterBar.isShowing ? .controlAccentColor : .secondaryLabelColor
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

    /// Writes the Data tab's table, filter and sort into the SQL tab as a SELECT, unless the SQL
    /// there is someone's own. With no table chosen yet, it starts from the first.
    private func matchQueryToData() {
        guard let object = selected ?? objects.first,
              editor.string.isEmpty || editor.string == matchingSQL else { return }
        var sql = "SELECT * FROM \(Database.quote(object.name))"
        if object == selected, let filter = filterBar.condition {
            sql += "\nWHERE " + Database.inline(filter.bindings, into: filter.sql)
        }
        if object == selected, let sort {
            sql += "\nORDER BY \(Database.quote(sort.column)) \(sort.ascending ? "ASC" : "DESC")"
        }
        sql += "\nLIMIT 100;"
        guard sql != editor.string else { return }
        editor.string = sql
        matchingSQL = sql
        highlightSQL()
    }

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
        dataPane.isHidden = tab != .data || !hasTable
        filterButton.isHidden = dataPane.isHidden
        structureView.isHidden = tab != .structure || !hasTable
        querySplit.isHidden = tab != .query || database == nil
        emptyLabel.isHidden = !(dataPane.isHidden && structureView.isHidden && querySplit.isHidden)
        emptyLabel.stringValue = database == nil
            ? tr("按工具列的資料夾按鈕開啟 SQLite 資料庫（⌘O），或按 ⌘N 新增一個。",
                 "Open an SQLite database with the folder button (⌘O), or make a new one with ⌘N.")
            : objects.isEmpty
            ? tr("這個資料庫還沒有資料表。到「SQL」分頁用 CREATE TABLE 建立。",
                 "This database has no tables yet. Make one with CREATE TABLE in the SQL tab.")
            : tr("從左邊選一個資料表。", "Choose a table on the left.")
        // Showing a SELECT written to match the Data tab, its rows come along with it.
        if tab == .query, database != nil, let sql = matchingSQL, editor.string == sql, ranMatchingSQL != sql {
            ranMatchingSQL = sql
            runQuery(nil)
        }
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

    /// A word on what just happened, shown before the Data tab's row count for a few seconds.
    private var notice: String?

    private func showNotice(_ text: String) {
        notice = text
        updateFooter()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard self?.notice == text else { return }
            self?.notice = nil
            self?.updateFooter()
        }
    }

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
            let filtered = filterBar.condition != nil
            statusLabel.stringValue = (notice.map { $0 + " · " } ?? "") + (total == 0
                ? (filtered ? tr("沒有符合的資料", "No matching rows") : tr("沒有資料", "No rows"))
                : tr("第 \(offset + 1)–\(offset + shown) 列，共 \(total) 列", "Rows \(offset + 1)–\(offset + shown) of \(total)")
                    + (filtered ? tr("（已篩選）", " (filtered)") : ""))
                + (dataGrid.editable || selected?.kind == .view ? "" : tr("（唯讀）", " (read-only)"))
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = ""
        }
    }

    // MARK: - Refresh and export

    @objc func refresh(_ sender: Any?) {
        reloadObjects()
        filterBar.update(columns: selectedColumns)
        updateFilterButton()
        loadPage()
        loadStructure()
    }

    /// Shows where the database is and how big, and lets it be compacted.
    @objc func showDatabaseInfo(_ sender: Any?) {
        guard let database else { return NSSound.beep() }
        let window = DatabaseInfoWindow(database: database)
        window.onChange = { [weak self] in self?.refresh(nil) }
        keepingPopoverOpen { window.run() }
    }

    /// Imports a CSV file into the selected table (or the one right-clicked), in one transaction:
    /// every row goes in, or on an error none does.
    @objc func importCSV(_ sender: Any?) {
        guard canChangeSchema, let database, let object = actedOn, object.kind == .table else { return NSSound.beep() }
        let open = NSOpenPanel()
        open.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        open.message = tr("選擇要匯入「\(object.name)」的 CSV 檔", "Choose a CSV file to import into “\(object.name)”")
        guard keepingPopoverOpen({ open.runModal() }) == .OK, let url = open.url else { return }
        let columns: [Column]
        let text: String
        do {
            guard let read = CSV.text(of: try Data(contentsOf: url)) else {
                return showError(tr("無法讀取「\(url.lastPathComponent)」", "Couldn’t read “\(url.lastPathComponent)”"),
                                 DatabaseError(message: tr("無法辨識檔案的文字編碼。", "Its text encoding isn’t one MenuSQLite knows.")))
            }
            text = read
            columns = try database.columns(of: object.name)
        } catch {
            return showError(tr("無法讀取「\(url.lastPathComponent)」", "Couldn’t read “\(url.lastPathComponent)”"), error)
        }
        let window = ImportWindow(text: text, fileName: url.lastPathComponent, table: object.name, columns: columns)
        guard keepingPopoverOpen({ window.run() }), let plan = window.result else { return }
        do {
            try database.run(plan.script)
        } catch {
            _ = try? database.run("ROLLBACK")   // on this Mac the transaction is still open; over SSH it's gone
            return showError(tr("無法匯入，資料表沒有變更", "Couldn’t import; the table is unchanged"), error)
        }
        // Show the table it went into, with its new rows.
        if let row = objects.firstIndex(of: object), sidebar.selectedRow != row {
            sidebar.selectRowIndexes([row], byExtendingSelection: false)
        }
        tab = .data
        refresh(nil)
        showNotice(tr("已匯入 \(plan.rows.count) 列", "Imported \(plan.rows.count) row\(plan.rows.count == 1 ? "" : "s")"))
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

    // MARK: - Structure document

    private var schemaWindows: [SchemaWindow] = []

    /// Writes the structure of every table and view as Markdown and shows it in its own window.
    @objc func showSchemaDocument(_ sender: Any?) {
        guard let database else { return NSSound.beep() }
        let markdown: String
        do {
            markdown = try SchemaDocument.markdown(for: database)
        } catch {
            return showError(tr("無法製作結構文件", "Couldn’t make the structure document"), error)
        }
        let window = SchemaWindow(databaseName: database.name, markdown: markdown) { [weak database] in
            guard let database else { throw DatabaseError(message: tr("資料庫已關閉。", "The database is closed.")) }
            return try SchemaDocument.markdown(for: database)
        }
        window.onClose = { [weak self, weak window] in self?.schemaWindows.removeAll { $0 === window } }
        schemaWindows.append(window)
        // The popover floats above ordinary windows, pinned or not, and would cover the document.
        closePopover(nil)
        window.present()
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
        // The pinned window has a size of its own (saved with its place); the popover's size is
        // left as it was, for when the pin comes off.
        if inPinnedWindow, let window = view.window {
            var frame = window.frame
            let top = frame.maxY
            frame.size = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
            frame.origin.y = top - frame.height
            preferredContentSize = size
            window.setFrame(frame, display: true)
            return
        }
        preferredContentSize = size
        popover?.contentSize = size
        savedSize = size
        view.window?.invalidateCursorRects(for: view)
    }

    @objc func resetSize(_ sender: Any?) {
        resize(to: Self.defaultSize)
    }

    /// Back in the popover after being pinned: the size it had before.
    func restorePopoverSize() {
        resize(to: savedSize)
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
        guard !pinned || canUnpin else { return NSSound.beep() }
        pinned.toggle()
    }

    /// Hides the window; a pinned one stays pinned, and comes back where it was.
    @objc func closePopover(_ sender: Any?) {
        if inPinnedWindow { return view.window!.orderOut(sender) }
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
        add(menu, tr("連線到伺服器上的資料庫…", "Open a Database on a Server…"), #selector(connectRemote(_:)), key: "O")
        add(menu, tr("資料庫資訊…", "Database Info…"), #selector(showDatabaseInfo(_:)), key: "i")
        add(menu, tr("匯入 CSV…", "Import CSV…"), #selector(importCSV(_:)), key: "I")
        add(menu, tr("匯出 CSV…", "Export CSV…"), #selector(exportCSV(_:)), key: "E")
        add(menu, tr("結構文件（Markdown）…", "Structure Document (Markdown)…"), #selector(showSchemaDocument(_:)), key: "D")
        menu.addItem(.separator())
        add(menu, tr("新增資料表…", "New Table…"), #selector(newTable(_:)), key: "n").keyEquivalentModifierMask = [.command, .option]
        add(menu, tr("新增視圖…", "New View…"), #selector(newView(_:)), key: "N").keyEquivalentModifierMask = [.command, .option, .shift]
        add(menu, tr("編輯資料表或視圖…", "Edit Table or View…"), #selector(editTable(_:)), key: "e").keyEquivalentModifierMask = [.command, .option]
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
        // One of the two stays on, or there'd be no way back: the last one on can't be turned off.
        let dock = add(menu, tr("顯示在 Dock", "Show in Dock"), #selector(toggleShowInDock(_:)))
        dock.state = Presence.showInDock ? .on : .off
        let menuBar = add(menu, tr("顯示在選單列", "Show in Menu Bar"), #selector(toggleShowInMenuBar(_:)))
        menuBar.state = Presence.showInMenuBar ? .on : .off
        let hint = NSMenuItem(title: tr("Dock 和選單列至少要顯示一個", "Shows in the Dock, the menu bar, or both"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        add(menu, tr("關於隨手SQLite", "About MenuSQLite"), #selector(showAbout(_:)))
        menu.addItem(withTitle: tr("結束隨手SQLite", "Quit MenuSQLite"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
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

    @objc private func toggleShowInDock(_ sender: Any?) { Presence.showInDock.toggle() }
    @objc private func toggleShowInMenuBar(_ sender: Any?) { Presence.showInMenuBar.toggle() }

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
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString(string: "Created by : Jeff Lee\n", attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        let icon = NSTextAttachment()
        icon.image = Self.githubMark
        // Sits the mark on the baseline at about the height of a capital letter.
        let side = font.capHeight + 3
        icon.bounds = NSRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
        let iconString = NSMutableAttributedString(attachment: icon)
        iconString.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: iconString.length))
        credits.append(iconString)
        // "account / repo", as GitHub shows it, with only the repository name linked.
        credits.append(NSAttributedString(string: " janfon-source / ", attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]))
        credits.append(NSAttributedString(string: "MenuSQLite", attributes: [
            .font: font,
            .link: URL(string: "https://github.com/janfon-source/MenuSQLite")!,
            .paragraphStyle: paragraph,
        ]))
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: tr("隨手SQLite", "MenuSQLite"), .credits: credits])
    }

    /// GitHub's mark (the Octicon mark-github, 16×16), drawn in the label color so it follows
    /// light and dark appearance.
    private static let githubMark: NSImage = {
        let svg = "M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"
        let path = svgPath(svg)
        return NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            NSColor.labelColor.setFill()
            path.fill()
            return true
        }
    }()

    /// Builds a path from SVG path data, enough for the GitHub mark: M, C, A and Z, absolute or
    /// relative, with repeated arguments.
    private static func svgPath(_ data: String) -> NSBezierPath {
        let path = NSBezierPath()
        let scanner = Scanner(string: data)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n")
        var command: Character = "M"
        var current = NSPoint.zero
        var start = NSPoint.zero
        func number() -> CGFloat { CGFloat(scanner.scanDouble() ?? 0) }
        // Arc flags may run together with the next number ("0 1-5.45"), so read them one digit at a time.
        func flag() -> Bool {
            _ = scanner.scanCharacters(from: CharacterSet(charactersIn: " ,"))
            return scanner.scanCharacter() == "1"
        }
        while !scanner.isAtEnd {
            let index = scanner.currentIndex
            if let c = scanner.scanCharacter(), c.isLetter {
                command = c
            } else {
                scanner.currentIndex = index
            }
            let relative = command.isLowercase
            let base = relative ? current : .zero
            switch command.uppercased() {
            case "M":
                current = NSPoint(x: base.x + number(), y: base.y + number())
                start = current
                path.move(to: current)
                command = relative ? "l" : "L"
            case "L":
                current = NSPoint(x: base.x + number(), y: base.y + number())
                path.line(to: current)
            case "C":
                let c1 = NSPoint(x: base.x + number(), y: base.y + number())
                let c2 = NSPoint(x: base.x + number(), y: base.y + number())
                current = NSPoint(x: base.x + number(), y: base.y + number())
                path.curve(to: current, controlPoint1: c1, controlPoint2: c2)
            case "A":
                var r = number()
                _ = number()  // The mark's arcs are circles, so the second radius and rotation are ignored.
                _ = number()
                let large = flag(), sweep = flag()
                let end = NSPoint(x: base.x + number(), y: base.y + number())
                // The center, from the SVG endpoint parameterization for a circle.
                let mid = NSPoint(x: (current.x + end.x) / 2, y: (current.y + end.y) / 2)
                let dx = end.x - current.x, dy = end.y - current.y
                let half = hypot(dx, dy) / 2
                r = max(r, half)
                let h = sqrt(max(r * r - half * half, 0)) * (large == sweep ? -1 : 1)
                let center = NSPoint(x: mid.x - h * dy / (2 * half), y: mid.y + h * dx / (2 * half))
                let a1 = atan2(current.y - center.y, current.x - center.x) * 180 / .pi
                let a2 = atan2(end.y - center.y, end.x - center.x) * 180 / .pi
                path.appendArc(withCenter: center, radius: r, startAngle: a1, endAngle: a2, clockwise: !sweep)
                current = end
            case "Z":
                path.close()
                current = start
            default:
                return path
            }
        }
        return path
    }
}

extension MainViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(refresh(_:)), #selector(exportCSV(_:)), #selector(showDatabaseInfo(_:)), #selector(showSchemaDocument(_:)), #selector(runQuery(_:)), #selector(showQueryTab(_:)):
            return database != nil
        case #selector(showDataTab(_:)), #selector(showStructureTab(_:)), #selector(toggleFilter(_:)):
            return selected != nil
        case #selector(toggleShowInDock(_:)):
            return !Presence.showInDock || Presence.showInMenuBar
        case #selector(toggleShowInMenuBar(_:)):
            return !Presence.showInMenuBar || Presence.showInDock
        case #selector(addRow(_:)):
            return dataGrid.editable && tab == .data
        case #selector(newTable(_:)), #selector(newView(_:)):
            return canChangeSchema
        case #selector(editTable(_:)):
            return canChangeSchema && actedOn != nil
        case #selector(importCSV(_:)):
            return canChangeSchema && actedOn?.kind == .table
        case #selector(deleteTable(_:)):
            return canChangeSchema && actedOn != nil
        default:
            return true
        }
    }
}
