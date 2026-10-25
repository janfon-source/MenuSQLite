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

    /// The database in the tab showing, if any.
    var database: DatabaseConnection? { active.map { sessions[$0].database } }
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
    /// The tables on the left, the selected one's rows on the right.
    private let bodySplit = NSSplitView()
    private let tabs = NSSegmentedControl()
    private let content = NSView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let dataGrid = Grid()
    private let filterBar = FilterBar()
    private var dataPane: NSStackView!
    private var filterButton: NSButton!
    private var columnsButton: NSButton!
    /// The Structure tab's menu of things to do to the table: compact, analyze, export, print, AUTOINCREMENT, empty.
    private var tableMenuButton: NSButton!
    /// Columns left out of the Data tab, by table, for as long as the app runs. Every column
    /// shows until some are unticked.
    private var hiddenColumns: [String: Set<String>] = [:]
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
    /// Under the Data and SQL tabs: exports every row the filter lets through, in the columns
    /// showing, or the SQL tab's results.
    private var exportRowsButton: NSButton!
    /// Under the Data tab: reads the page showing again, as it is (filter, sort, page).
    private var reloadRowsButton: NSButton!
    private var deleteRowButton: NSButton!
    private var previousButton: NSButton!
    private var nextButton: NSButton!
    private var pageDivider: NSView!
    private var importButton: NSButton!
    /// Toolbar buttons that act on the open database: Refresh, Export, Info, Structure Document.
    private var databaseButtons: [NSButton] = []
    private var runButton: NSButton!
    /// Where the SQL tab's ▶︎ stands: blue while running, dark once the SQL has changed, and
    /// off once it has run, until the SQL changes again (⌘↩ still runs it again from the menu).
    private enum RunState { case changed, running, done }
    private var runState = RunState.done {
        didSet { updateRunButton() }
    }
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
            toolButton("star", "常用資料庫：開啟、加入目前的資料庫、管理", "Favorite Databases: open, add this one, manage",
                       #selector(showFavoritesMenu(_:))),
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

        let body = bodySplit
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
        tabStrip.spacing = 4
        tabStrip.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 6, right: 10)
        tabStrip.setHuggingPriority(.required, for: .vertical)
        tabStrip.isHidden = true
        let column = NSStackView(views: [header, tabStrip, topLine, body, bottomLine, footer])
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
            tabStrip.widthAnchor.constraint(equalTo: column.widthAnchor),
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

        // Over everything, while statements run off the main thread.
        busyOverlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(busyOverlay)
        NSLayoutConstraint.activate([
            busyOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            busyOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            busyOverlay.topAnchor.constraint(equalTo: root.topAnchor),
            busyOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

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
        updateRunButton()
        body.setPosition(190, ofDividerAt: 0)
    }

    private func makeSidebar() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("object"))
        column.resizingMask = .autoresizingMask
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        // Its one column fills the list, however wide it's made; otherwise it stays at its
        // starting width and long names are cut short.
        sidebar.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        sidebar.rowHeight = 22
        sidebar.dataSource = self
        sidebar.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = sidebar
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        // Right-click a table to add, change, empty or delete tables.
        let menu = NSMenu()
        for (zh, en, action) in [("新增資料表…", "New Table…", #selector(newTable(_:))),
                                 ("新增視圖…", "New View…", #selector(newView(_:))),
                                 ("編輯…", "Edit…", #selector(editTable(_:))),
                                 ("匯入 CSV…", "Import CSV…", #selector(importCSV(_:))),
                                 ("清空…", "Empty…", #selector(emptyTable(_:))),
                                 ("刪除…", "Delete…", #selector(deleteTable(_:)))] {
            let item = menu.addItem(withTitle: tr(zh, en), action: action, keyEquivalent: "")
            item.target = self
        }
        sidebar.menu = menu
        let pane = NSStackView(views: [scroll])
        pane.orientation = .vertical
        pane.distribution = .fill
        pane.spacing = 0
        pane.setHuggingPriority(.init(1), for: .vertical)
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
            self?.loadPage(recount: false)
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
        // An icon at the right end; its color says whether there's something new to run.
        runButton = toolButton("play.fill", "執行（⌘↩）", "Run (⌘↩)", #selector(runQuery(_:)))
        runButton.keyEquivalent = "\r"
        runButton.keyEquivalentModifierMask = .command
        let runHint = NSTextField(labelWithString: "")
        runHint.textColor = .secondaryLabelColor
        runHint.font = .systemFont(ofSize: 11)
        runHint.lineBreakMode = .byTruncatingTail
        runHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        localized.append((runHint, "⌘↩ 執行選取的語句，沒有選取就執行全部", "⌘↩ runs the selection, or everything if nothing is selected"))
        let runSpacer = NSView()
        runSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let runBar = NSStackView(views: [runHint, runSpacer, runButton])
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
        columnsButton = toolButton("checklist", "選擇要顯示的欄位（⌥⌘K）", "Choose the Columns to Show (⌥⌘K)", #selector(showColumnsMenu(_:)))
        tableMenuButton = toolButton("gearshape", "資料表功能：壓縮、分析、匯出、列印、自動遞增值、清空",
                                     "Table Actions: compact, analyze, export, print, AUTOINCREMENT, empty", #selector(showTableMenu(_:)))
        let tabBar = NSStackView(views: [tabs, tabSpacer, columnsButton, filterButton, tableMenuButton])
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
        reloadRowsButton = smallButton("arrow.clockwise", "重新載入這一頁的資料（篩選、排序和頁數不變）",
                                       "Reload the Rows Showing (the filter, sort and page stay)", #selector(reloadRows(_:)))
        exportRowsButton = smallButton("square.and.arrow.up", "匯出 CSV：資料分頁依目前的篩選、排序和顯示的欄位匯出全部符合的資料列（不限 200 列）；SQL 分頁匯出查詢結果（自動帶入的 SELECT 不限 100 列）",
                                       "Export CSV: on the Data tab, every row the filter lets through, sorted as shown, in the columns showing (not just 200); on the SQL tab, the query’s results (the SELECT written for you without its LIMIT 100)",
                                       #selector(exportRows(_:)))
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
        let footer = NSStackView(views: [statusLabel, spacer, reloadRowsButton, exportRowsButton, addRowButton, deleteRowButton, pageDivider,
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

    /// Shows a database just opened, in a tab of its own, from its first table.
    private func show(_ database: DatabaseConnection) {
        _ = view   // reopening at launch comes before the window: the table list must exist
        // A tab of its own, starting fresh: no SQL of its own yet, nothing run.
        saveSession()
        sessions.append(Session(database))
        active = sessions.count - 1
        editor.string = ""
        matchingSQL = nil
        message = nil
        runState = .done
        shown = nil   // a table of the same name in another database is another table
        addRecent(database.recentKey)
        sort = nil
        offset = 0
        reloadObjects()
        fitSidebar()
        queryGrid.show(ResultSet())
        ranMatchingSQL = nil
        matchQueryToData()
        updateTitle()
        rebuildTabs()
        focus()
    }

    /// Closes the active tab and its database.
    @objc func closeDatabase(_ sender: Any?) {
        guard let active else { return NSSound.beep() }
        closeSession(active)
    }

    // MARK: - Database tabs

    /// One open database and how its tab was left: the table and tab showing, the page,
    /// sort and filter, and the SQL tab's statement and results.
    private final class Session {
        let database: DatabaseConnection
        var selected: String?
        var tab = Tab.data
        var offset = 0
        var sort: (column: String, ascending: Bool)?
        var filter: [FilterBar.Saved] = []
        var sql = ""
        var matchingSQL: String?
        var ranMatchingSQL: String?
        var results = ResultSet()
        var message: (text: String, error: Bool)?
        var runState = RunState.done

        init(_ database: DatabaseConnection) { self.database = database }
    }

    private var sessions: [Session] = []
    private var active: Int?
    /// The tabs, one per open database, under the toolbar.
    private let tabStrip = NSStackView()

    /// Keeps how the active tab looks, before another is shown.
    private func saveSession() {
        guard let active, sessions.indices.contains(active) else { return }
        let session = sessions[active]
        session.selected = selected?.name
        session.tab = tab
        session.offset = offset
        session.sort = sort
        session.filter = filterBar.saved
        session.sql = editor.string
        session.matchingSQL = matchingSQL
        session.ranMatchingSQL = ranMatchingSQL
        session.results = queryGrid.result
        session.message = message
        session.runState = runState
    }

    /// Shows the active tab as it was left. The table list and rows are read again, so they're
    /// up to date; the SQL tab's results are the ones it had.
    private func restoreSession() {
        guard let active, let database else { return clearConnection() }
        let session = sessions[active]
        objects = (try? database.objects()) ?? []
        sidebar.reloadData()
        let index = session.selected.flatMap { name in objects.firstIndex { $0.name == name } } ?? (objects.isEmpty ? nil : 0)
        // Marked as shown first, so selecting its row doesn't count as choosing a new table.
        shown = index.map { objects[$0] }
        if let index {
            sidebar.selectRowIndexes([index], byExtendingSelection: false)
            sidebar.scrollRowToVisible(index)
        } else {
            sidebar.deselectAll(nil)
        }
        filterBar.reset(columns: selectedColumns)
        if let shown, shown.name == session.selected {
            filterBar.restore(session.filter)
            sort = session.sort
            offset = session.offset
        } else {
            sort = nil
            offset = 0
        }
        updateFilterButton()
        dataGrid.hiddenColumns = hiddenColumns[columnsKey] ?? []
        updateColumnsButton()
        updateTableButtons()
        loadPage()
        loadStructure()
        editor.string = session.sql
        matchingSQL = session.matchingSQL
        ranMatchingSQL = session.ranMatchingSQL
        highlightSQL()
        queryGrid.show(session.results)
        message = session.message
        runState = session.runState
        tab = session.tab
        updateTitle()
        rebuildTabs()
        focus()
    }

    /// The screen with no database: after the last tab is closed.
    private func clearConnection() {
        shown = nil
        reloadObjects()
        queryGrid.show(ResultSet())
        editor.string = ""
        matchingSQL = nil
        ranMatchingSQL = nil
        message = nil
        updateTitle()
        runState = .done
        rebuildTabs()
        showTab()
    }

    private func switchToSession(_ index: Int) {
        guard sessions.indices.contains(index), index != active else { return }
        saveSession()
        active = index
        restoreSession()
    }

    /// Closes a tab and its database; the tab beside it shows instead.
    private func closeSession(_ index: Int) {
        guard sessions.indices.contains(index), let current = active else { return }
        sessions.remove(at: index)
        if sessions.isEmpty {
            active = nil
            return clearConnection()
        }
        if index == current {
            active = min(index, sessions.count - 1)
            restoreSession()
        } else {
            if index < current { active = current - 1 }
            rebuildTabs()
        }
    }

    @objc private func closeTab(_ sender: NSButton) {
        closeSession(sender.tag)
    }

    @objc func nextTab(_ sender: Any?) {
        guard let active, sessions.count > 1 else { return NSSound.beep() }
        switchToSession((active + 1) % sessions.count)
    }

    @objc func previousTab(_ sender: Any?) {
        guard let active, sessions.count > 1 else { return NSSound.beep() }
        switchToSession((active + sessions.count - 1) % sessions.count)
    }

    /// One tab per database: its name, and × to close it; then ＋ for another.
    private func rebuildTabs() {
        for view in tabStrip.arrangedSubviews { view.removeFromSuperview() }
        tabStrip.isHidden = sessions.isEmpty
        guard !sessions.isEmpty else { return }
        for (i, session) in sessions.enumerated() {
            tabStrip.addArrangedSubview(tabView(i, session))
        }
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: tr("開啟資料庫", "Open Database"))!
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))!, target: self, action: #selector(openDocument(_:)))
        add.isBordered = false
        add.contentTintColor = .secondaryLabelColor
        add.toolTip = tr("在新的標籤頁開啟資料庫（⌘O）", "Open a Database in a New Tab (⌘O)")
        add.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        tabStrip.addArrangedSubview(add)
        tabStrip.addArrangedSubview(spacer)
    }

    private func tabView(_ index: Int, _ session: Session) -> NSView {
        let isActive = index == active
        let database = session.database
        // A favorite's name when the database is one; else the file's name (where it is shows on
        // hovering). Tabs on the same database are told apart by a number, from the second on.
        let name = Favorites.matching(database.recentKey)?.name ?? database.name
        let twin = sessions[..<index].filter { $0.database.recentKey == database.recentKey }.count
        // A label, not a button, so the tab itself takes the mouse: a click picks it, a drag moves it.
        let title = NSTextField(labelWithString: name + (twin > 0 ? " (\(twin + 1))" : ""))
        title.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
        title.textColor = isActive ? .labelColor : .secondaryLabelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        var views: [NSView] = [title]
        if database is RemoteDatabase {
            let lock = NSImageView(image: NSImage(systemSymbolName: "network", accessibilityDescription: "SSH")!
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))!)
            lock.contentTintColor = title.textColor
            views.insert(lock, at: 0)
        }
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: tr("關閉", "Close"))!
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))!, target: self, action: #selector(closeTab(_:)))
        close.isBordered = false
        close.tag = index
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = tr("關閉這個資料庫的標籤頁", "Close This Database’s Tab")
        close.setContentHuggingPriority(.required, for: .horizontal)
        let chip = TabChip(views: views + [close], active: isActive)
        chip.toolTip = database.location + tr("（拖曳可調整順序）", " (drag to reorder)")
        chip.onSelect = { [weak self] in self?.switchToSession(index) }
        chip.onMove = { [weak self] from, to in self?.moveSession(from: from, to: to) }
        return chip
    }

    /// A tab dragged to another place: the databases take the new order, the same one showing.
    private func moveSession(from: Int, to: Int) {
        guard sessions.indices.contains(from), sessions.indices.contains(to), from != to else { return rebuildTabs() }
        let showing = active.map { sessions[$0] }
        sessions.insert(sessions.remove(at: from), at: to)
        active = showing.flatMap { session in sessions.firstIndex { $0 === session } }
        rebuildTabs()
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
        open(key: key)
    }

    /// Opens a database by how the recent list and favorites keep it: a path, or a server's key.
    func open(key: String) {
        if let remote = RemoteLocation(key: key) { open(remote) } else { open(URL(fileURLWithPath: key)) }
    }

    // MARK: Favorite databases

    /// The favorites, to open one; then adding the database open now, and managing them.
    @objc func showFavoritesMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let favorites = Favorites.all
        for favorite in favorites {
            let item = NSMenuItem(title: favorite.name, action: #selector(openFavorite(_:)), keyEquivalent: "")
            item.toolTip = favorite.summary
            item.representedObject = favorite.id.uuidString
            item.target = self
            item.image = NSImage(systemSymbolName: favorite.remote == nil ? "star" : "network", accessibilityDescription: nil)
            if favorite.key == database?.recentKey { item.state = .on }
            menu.addItem(item)
        }
        if favorites.isEmpty {
            let none = NSMenuItem(title: tr("還沒有常用資料庫", "No Favorite Databases Yet"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        add(menu, tr("將目前的資料庫加入常用資料庫…", "Add This Database to Favorites…"), #selector(addToFavorites(_:)), key: "d")
        add(menu, tr("管理常用資料庫…", "Manage Favorite Databases…"), #selector(manageFavorites(_:)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func openFavorite(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let favorite = Favorites.all.first(where: { $0.id.uuidString == id }) else { return }
        open(key: favorite.key)
    }

    /// Keeps the database open now under a name.
    @objc func addToFavorites(_ sender: Any?) {
        guard let database else { return NSSound.beep() }
        let key = database.recentKey
        if let existing = Favorites.matching(key) {
            let alert = NSAlert()
            alert.messageText = tr("已經在常用資料庫裡了", "Already a Favorite")
            alert.informativeText = tr("這個資料庫已經存成「\(existing.name)」。", "This database is saved as “\(existing.name)”.")
            keepingPopoverOpen { _ = alert.runModal() }
            return
        }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = Favorites.suggestedName(for: key)
        let alert = NSAlert()
        alert.messageText = tr("加入常用資料庫", "Add to Favorites")
        alert.informativeText = tr("記住 \(database.location)，之後從星號選單一鍵開啟。名稱：",
                                   "Remembers \(database.location), to open from the star menu later. Name:")
        alert.accessoryView = field
        alert.addButton(withTitle: tr("加入", "Add"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.window.initialFirstResponder = field
        guard keepingPopoverOpen({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        Favorites.all.append(Favorite(name: name.isEmpty ? Favorites.suggestedName(for: key) : name, key: key))
        rebuildTabs()   // the tab now goes by the favorite's name
        showNotice(tr("已加入常用資料庫", "Added to favorites"))
    }

    @objc func manageFavorites(_ sender: Any?) {
        let window = FavoritesWindow()
        keepingPopoverOpen { window.run() }
        rebuildTabs()   // names may have changed
        if let favorite = window.chosen { open(key: favorite.key) }
    }

    @objc private func clearRecent(_ sender: Any?) {
        recent = []
    }

    // MARK: - Tables

    private func updateTableButtons() {
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

    /// Widens the list (or narrows it back) so the longest table or view name shows whole,
    /// keeping at least half the window for the rows. Done when a database is opened, so a width
    /// dragged by hand stays through refreshes.
    private func fitSidebar() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let longest = objects.map { ($0.name as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        // The icon and the gaps around it, the source list's insets, and room for a scroller.
        let wanted = ceil(longest) + 16 + 6 + 4 + 36 + 16
        let width = min(max(wanted, 190), max(190, bodySplit.bounds.width * 0.5))
        bodySplit.setPosition(width, ofDividerAt: 0)
        bodySplit.layoutSubtreeIfNeeded()
        sidebar.sizeLastColumnToFit()
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
        // The whole name, for when the list is still too narrow for it.
        cell.toolTip = object.name + (object.kind == .view ? tr("（視圖，唯讀）", " (view, read-only)") : "")
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
        dataGrid.hiddenColumns = hiddenColumns[columnsKey] ?? []
        updateColumnsButton()
        loadPage()
        matchQueryToData()   // after the page, whose columns the SELECT may list
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

    /// Deletes every row of the table right-clicked in the list, keeping the table itself.
    @objc func emptyTable(_ sender: Any?) { empty(actedOn) }

    /// The Structure tab's menu acts on the table showing.
    @objc func emptySelectedTable(_ sender: Any?) { empty(selected) }

    private func empty(_ object: DatabaseObject?) {
        guard canChangeSchema, let database, let object, object.kind == .table else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = tr("要清空資料表「\(object.name)」嗎？", "Empty the table “\(object.name)”?")
        alert.informativeText = tr("資料表中的所有資料都會刪除，無法復原；資料表結構會保留。",
                                   "All rows in the table will be deleted. This can’t be undone; the table itself stays.")
        alert.addButton(withTitle: tr("清空", "Empty")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("取消", "Cancel"))
        guard keepingPopoverOpen({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        do {
            // SQLite has no TRUNCATE; a DELETE without WHERE empties the table just as fast.
            try database.run("DELETE FROM \(Database.quote(object.name))")
        } catch {
            return showError(tr("無法清空", "Couldn’t empty the table"), error)
        }
        guard selected?.name == object.name else { return }
        loadPage()
        if tab == .structure { refreshStructure() }
    }

    /// Runs the editor's SQL, then shows the table as it is now at once: the Data tab's columns
    /// in their new order, the filter's columns, the Structure tab and the SQL tab's SELECT.
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
        // Read now rather than when the tab is next shown (refresh read it if it's showing).
        if structureStale { refreshStructure() }
        matchQueryToData()
    }

    // MARK: - Data tab

    /// Shows the current page of the selected table's rows, read off the main thread. With
    /// `recount`, the rows are counted and the table checked for rowids again; paging and
    /// sorting don't need to, and are a single query. `done` runs once the page shows.
    private func loadPage(recount: Bool = true, then done: (() -> Void)? = nil) {
        guard database != nil, let object = selected else {
            dataGrid.show(ResultSet())
            rowIDs = []
            total = 0
            updateFooter()
            done?()
            return
        }
        let filter = filterBar.condition, sort = self.sort, requested = offset, pageSize = self.pageSize
        let known = recount ? nil : (editable: dataGrid.editable, total: total)
        perform(tr("正在讀取資料…", "Loading data…"), cancellable: true) { database in
            let editable = known?.editable ?? (!database.readOnly && database.hasRowID(object))
            let total = try known?.total ?? database.rowCount(of: object.name, filter: filter)
            var offset = requested
            if offset >= total, total > 0 { offset = (total - 1) / pageSize * pageSize }
            let page = try database.rows(of: object, filter: filter, orderBy: sort?.column, ascending: sort?.ascending ?? true,
                                         limit: pageSize, offset: offset, rowIDs: editable)
            return (editable: editable, total: total, offset: offset, page: page)
        } then: { [weak self] result in
            guard let self else { return }
            // Another table chosen meanwhile has its own page coming.
            guard self.selected == object else { return }
            switch result {
            case .success(let loaded):
                self.total = loaded.total
                self.offset = loaded.offset
                var page = loaded.page
                if loaded.editable {
                    // The rowid came first, to find each row again when it's edited; it isn't shown.
                    self.rowIDs = page.rows.map { if case .integer(let id) = $0[0] { return id }; return 0 }
                    page.columns.removeFirst()
                    page.rows = page.rows.map { Array($0.dropFirst()) }
                } else {
                    self.rowIDs = []
                }
                self.dataGrid.editable = loaded.editable
                self.dataGrid.show(page, sortedBy: sort)
                self.updateFooter()
            case .failure(let error):
                self.dataGrid.show(ResultSet())
                self.rowIDs = []
                self.showStatus(DatabaseError.wasCancelled(error) ? tr("已取消讀取資料", "Loading cancelled") : error.localizedDescription,
                                error: true)
            }
            done?()
        }
    }

    private func edit(row: Int, column: Int, to value: Value) {
        guard let database, let table = selected?.name, rowIDs.indices.contains(row) else { return }
        do {
            try database.update(table, column: dataGrid.result.columns[column], to: value, rowID: rowIDs[row])
            let selection = dataGrid.tableView.selectedRowIndexes
            loadPage { [weak self] in
                guard let self else { return }
                self.dataGrid.tableView.selectRowIndexes(selection.filteredIndexSet { $0 < self.dataGrid.tableView.numberOfRows },
                                                         byExtendingSelection: false)
            }
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
            loadPage { [weak self] in
                guard let self, let row = self.rowIDs.firstIndex(of: id) else { return }
                self.dataGrid.tableView.selectRowIndexes([row], byExtendingSelection: false)
                self.dataGrid.tableView.scrollRowToVisible(row)
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

    // MARK: Columns shown

    /// Where the selected table's hidden columns are kept: the database file and the table.
    private var columnsKey: String {
        [database?.recentKey ?? "", selected?.name ?? ""].joined(separator: "\u{0}")
    }

    /// The columns showing on the Data tab, in order, when some are hidden; nil when all show.
    private var shownColumns: [String]? {
        let hidden = dataGrid.hiddenColumns
        let columns = dataGrid.result.columns
        guard !hidden.isEmpty, columns.contains(where: hidden.contains) else { return nil }
        return columns.filter { !hidden.contains($0) }
    }

    /// A menu of the table's columns, each with a checkbox. Ticking one shows it at once and
    /// the menu stays open, so several can be changed in one go.
    @objc func showColumnsMenu(_ sender: Any?) {
        guard selected != nil, !dataGrid.result.columns.isEmpty else { return NSSound.beep() }
        if tab != .data { tab = .data }
        let menu = NSMenu()
        let all = menu.addItem(withTitle: tr("全部顯示", "Show All"), action: #selector(showAllColumns(_:)), keyEquivalent: "")
        all.target = self
        all.isEnabled = !dataGrid.hiddenColumns.isEmpty
        menu.addItem(.separator())
        let names = dataGrid.result.columns
        let font = NSFont.menuFont(ofSize: 0)
        let width = max(180, (names.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + 60)
        for name in names {
            let box = NSButton(checkboxWithTitle: name, target: self, action: #selector(toggleColumn(_:)))
            box.state = dataGrid.hiddenColumns.contains(name) ? .off : .on
            box.font = font
            box.frame = NSRect(x: 14, y: 2, width: width - 20, height: 20)
            let holder = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
            holder.addSubview(box)
            let item = NSMenuItem()
            item.view = holder
            menu.addItem(item)
        }
        menu.allowsContextMenuPlugIns = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: columnsButton.bounds.height + 4), in: columnsButton)
    }

    @objc private func toggleColumn(_ sender: NSButton) {
        var hidden = dataGrid.hiddenColumns
        if sender.state == .on {
            hidden.remove(sender.title)
        } else {
            // One column at least stays, or there'd be nothing to see the rows by.
            guard dataGrid.result.columns.contains(where: { $0 != sender.title && !hidden.contains($0) }) else {
                sender.state = .on
                return NSSound.beep()
            }
            hidden.insert(sender.title)
        }
        setHiddenColumns(hidden)
    }

    @objc private func showAllColumns(_ sender: Any?) {
        setHiddenColumns([])
    }

    private func setHiddenColumns(_ hidden: Set<String>) {
        dataGrid.hiddenColumns = hidden
        hiddenColumns[columnsKey] = hidden.isEmpty ? nil : hidden
        updateColumnsButton()
        updateFooter()
        matchQueryToData()
    }

    private func updateColumnsButton() {
        columnsButton.contentTintColor = dataGrid.hiddenColumns.isEmpty ? .secondaryLabelColor : .controlAccentColor
    }

    private func updateFilterButton() {
        filterButton.contentTintColor = filterBar.isShowing ? .controlAccentColor : .secondaryLabelColor
    }

    /// Reads the rows showing again (another program, or the SQL tab, may have changed them),
    /// keeping the filter, sort, page and selection; then says so for a moment.
    @objc func reloadRows(_ sender: Any?) {
        guard selected != nil else { return NSSound.beep() }
        let selection = dataGrid.tableView.selectedRowIndexes
        loadPage { [weak self] in
            guard let self else { return }
            self.dataGrid.tableView.selectRowIndexes(selection.filteredIndexSet { $0 < self.dataGrid.tableView.numberOfRows },
                                                     byExtendingSelection: false)
            self.showNotice(tr("已重新載入", "Reloaded"))
        }
    }

    @objc func previousPage(_ sender: Any?) {
        guard offset > 0 else { return }
        offset = max(0, offset - pageSize)
        loadPage(recount: false)
    }

    @objc func nextPage(_ sender: Any?) {
        guard offset + pageSize < total else { return }
        offset += pageSize
        loadPage(recount: false)
    }

    // MARK: - Structure tab

    /// Whether the Structure tab shows an older table, or older facts, than it should. It's read
    /// again when it next shows, so choosing tables on the Data tab doesn't wait for it.
    private var structureStale = true

    private func loadStructure() {
        structureStale = true
        if isViewLoaded, tab == .structure { refreshStructure() }
    }

    /// What the Structure tab shows of a table or view.
    private struct StructureInfo {
        var facts: TableFacts?
        var rows = 0
        var columns: [Column] = []
        var indexes: [Index]?
        var create: String?
    }

    /// Reads the structure off the main thread, and shows it.
    private func refreshStructure() {
        structureStale = false
        guard database != nil, let object = selected else {
            structureText.textStorage?.setAttributedString(NSAttributedString())
            return
        }
        perform(tr("正在讀取結構…", "Loading the structure…"), cancellable: true) { database in
            var info = StructureInfo()
            if object.kind == .table {
                info.facts = try database.facts(of: object.name)
                if info.facts != nil { info.rows = try database.rowCount(of: object.name) }
                info.indexes = try database.indexes(of: object.name)
            }
            info.columns = try database.columns(of: object.name)
            info.create = try database.createStatement(of: object.name)
            return info
        } then: { [weak self] result in
            guard let self, self.selected == object else { return }
            self.showStructure(result)
        }
    }

    private func showStructure(_ result: Result<StructureInfo, Error>) {
        let text = NSMutableAttributedString()
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
        let font = body[.font] as! NSFont
        switch result {
        case .failure(let error):
            line(DatabaseError.wasCancelled(error) ? tr("已取消讀取", "Loading cancelled") : error.localizedDescription, color: .systemRed)
        case .success(let info):
            if let facts = info.facts {
                heading(tr("資料表資訊", "Table Info"))
                let rows = SchemaDocument.factRows(facts, rows: info.rows)
                let paragraph = NSMutableParagraphStyle()
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: (rows.map {
                    ($0[0] as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + 16)]
                for row in rows {
                    let entry = NSMutableAttributedString(string: row[0] + "\t", attributes: [
                        .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.secondaryLabelColor])
                    entry.append(NSAttributedString(string: row[1] + "\n", attributes: [
                        .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]))
                    text.append(entry)
                }
            }
            heading(tr("欄位", "Columns"))
            let rows = [[tr("名稱", "Name"), tr("類型", "Type"), tr("非空", "Not Null"), tr("預設值", "Default"), tr("主鍵", "Key")]]
                + info.columns.map { [$0.name, $0.type, $0.notNull ? "✓" : "", $0.defaultValue ?? "", $0.primaryKey > 0 ? "\($0.primaryKey)" : ""] }
            // Tab stops at each column's widest text keep the columns lined up, Chinese included.
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
            if let indexes = info.indexes {
                heading(tr("索引", "Indexes"))
                if indexes.isEmpty { line(tr("（沒有）", "(none)"), color: .secondaryLabelColor) }
                for index in indexes {
                    line("\(index.name)\(index.unique ? " UNIQUE" : "")  (\(index.columns.joined(separator: ", ")))")
                }
            }
            if let sql = info.create {
                heading(tr("建立語句", "CREATE Statement"))
                let statement = NSMutableAttributedString(string: sql + "\n", attributes: body)
                SyntaxHighlighter.highlight(statement, language: "sql")
                text.append(statement)
            }
        }
        structureText.textStorage?.setAttributedString(text)
    }

    // MARK: - Working off the main thread

    /// One queue for every database's statements, run in the order they were asked for.
    private static let work = DispatchQueue(label: "com.jeff.menusqlite.work", qos: .userInitiated)
    private let busyOverlay = BusyOverlay()
    private var pendingWork = 0
    /// Whether Cancel was pressed since the window was last free.
    private var cancelRequested = false
    /// SQL runs asked for and not yet done, so the ▶︎ stays blue until the last of them ends.
    private var runsPending = 0

    /// Runs `body` against the database off the main thread, the window covered meanwhile with
    /// `message` (after a moment, so quick statements don't flash it), then hands its result to
    /// `done` back on the main thread. With `rows`, the cover counts the rows coming in (on this
    /// Mac); with `cancellable`, it has a Cancel button (and Esc) that stops the statement.
    private func perform<T>(_ message: String, rows: Bool = false, cancellable: Bool = false,
                            _ body: @escaping (DatabaseConnection) throws -> T,
                            then done: @escaping (Result<T, Error>) -> Void) {
        guard let database else { return }
        if pendingWork == 0 { cancelRequested = false }
        pendingWork += 1
        busyOverlay.show(message)
        busyOverlay.onCancel = cancellable ? { [weak self, weak database] in
            self?.cancelRequested = true
            database?.cancel()
        } : nil
        let overlay = busyOverlay
        Self.work.async {
            if rows {
                database.onRows = { count in
                    DispatchQueue.main.async {
                        overlay.detail = tr("已讀取 \(count.formatted()) 列", "\(count.formatted()) rows read")
                    }
                }
            }
            let result = Result { try body(database) }
            database.onRows = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingWork -= 1
                if self.pendingWork == 0 { self.busyOverlay.hide() }
                done(result)
            }
        }
    }

    /// Whether SQL might change tables or rows: anything but statements that only read.
    static func mayChange(_ sql: String) -> Bool {
        let reading: Set<String> = ["SELECT", "EXPLAIN", "VALUES"]
        // Comments out, then the first word of each statement. PRAGMA may set as well as read.
        var text = sql.replacingOccurrences(of: #"(?s)/\*.*?\*/"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)--.*$"#, with: " ", options: .regularExpression)
        return text.split(separator: ";").contains { statement in
            guard let word = statement.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first else { return false }
            return !reading.contains(word.uppercased())
        }
    }

    // MARK: - Table actions

    @objc func showTableMenu(_ sender: Any?) {
        guard let database, let object = selected else { return NSSound.beep() }
        if tab != .structure { tab = .structure }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ zh: String, _ en: String, _ action: Selector, enabled: Bool = true) {
            let item = menu.addItem(withTitle: tr(zh, en), action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
        }
        let writable = !database.readOnly
        if object.kind == .table {
            item("壓縮資料庫（VACUUM）", "Compact Database (VACUUM)", #selector(vacuumDatabase(_:)), enabled: writable)
            item("分析資料表（ANALYZE）", "Analyze Table (ANALYZE)", #selector(analyzeTable(_:)), enabled: writable)
            menu.addItem(.separator())
        }
        item("匯出 Markdown…", "Export Markdown…", #selector(exportTableMarkdown(_:)))
        item("列印…", "Print…", #selector(printTable(_:)))
        if object.kind == .table {
            let auto = writable && (try? database.facts(of: object.name))??.autoIncrement == true
            menu.addItem(.separator())
            item("重設自動遞增值", "Reset AUTOINCREMENT", #selector(resetAutoIncrement(_:)), enabled: auto)
            item("將自動遞增值設為…", "Set AUTOINCREMENT to…", #selector(setAutoIncrement(_:)), enabled: auto)
            menu.addItem(.separator())
            item("清空資料…", "Empty Table…", #selector(emptySelectedTable(_:)), enabled: writable)
        }
        // Its right edge under the button's, so it opens into the window rather than past it.
        menu.popUp(positioning: nil, at: NSPoint(x: tableMenuButton.bounds.width - menu.size.width,
                                                 y: tableMenuButton.bounds.height + 4), in: tableMenuButton)
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        keepingPopoverOpen { _ = alert.runModal() }
    }

    /// SQLite has no OPTIMIZE for one table; VACUUM rebuilds the whole file, this table with it.
    @objc func vacuumDatabase(_ sender: Any?) {
        guard database != nil, let object = selected, object.kind == .table else { return NSSound.beep() }
        perform(tr("正在壓縮資料庫（VACUUM）…", "Compacting the database (VACUUM)…"), cancellable: true) { database in
            let before = (try? database.facts(of: object.name))??.totalLength
            try database.run("VACUUM")
            return (before, (try? database.facts(of: object.name))??.totalLength)
        } then: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (before, after)):
                self.loadStructure()
                var text = tr("VACUUM 重建了整個資料庫檔案，把刪除資料後留下的空間還給系統。",
                              "VACUUM rebuilt the whole database file, giving back the space deleted rows left.")
                if let before, let after {
                    text += "\n\n" + tr("這個資料表：", "This table: ") + "\(TableFacts.bytes(before)) → \(TableFacts.bytes(after))"
                }
                self.inform(tr("已壓縮資料庫", "Database compacted"), text)
            case .failure(let error) where DatabaseError.wasCancelled(error):
                self.showNotice(tr("已取消 VACUUM，資料庫沒有變更", "VACUUM cancelled; the database is unchanged"))
            case .failure(let error):
                self.showError(tr("無法執行 VACUUM", "Couldn’t run VACUUM"), error)
            }
        }
    }

    @objc func analyzeTable(_ sender: Any?) {
        guard database != nil, let object = selected, object.kind == .table else { return NSSound.beep() }
        perform(tr("正在分析資料表（ANALYZE）…", "Analyzing the table (ANALYZE)…"), cancellable: true) { database in
            try database.run("ANALYZE \(Database.quote(object.name))")
        } then: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.loadStructure()
                self.inform(tr("已分析資料表", "Table analyzed"),
                            tr("索引的統計資料已更新（存在 sqlite_stat1），查詢計畫會更準確。",
                               "The index statistics are up to date (in sqlite_stat1), for better query plans."))
            case .failure(let error) where DatabaseError.wasCancelled(error):
                self.showNotice(tr("已取消 ANALYZE", "ANALYZE cancelled"))
            case .failure(let error):
                self.showError(tr("無法執行 ANALYZE", "Couldn’t run ANALYZE"), error)
            }
        }
    }

    /// The table's Markdown document, written off the main thread, for `use` once it's ready.
    private func tableDocument(_ failure: String, _ use: @escaping (String, DatabaseObject, DatabaseConnection) -> Void) {
        guard database != nil, let object = selected else { return NSSound.beep() }
        perform(tr("正在產生 Markdown…", "Writing the Markdown…")) { database in
            (try SchemaDocument.markdown(for: object, in: database), database)
        } then: { [weak self] result in
            switch result {
            case .success(let (markdown, database)): use(markdown, object, database)
            case .failure(let error): self?.showError(failure, error)
            }
        }
    }

    @objc func exportTableMarkdown(_ sender: Any?) {
        tableDocument(tr("無法匯出", "Couldn’t export")) { [weak self] markdown, object, _ in
            self?.saveTableMarkdown(markdown, of: object)
        }
    }

    private func saveTableMarkdown(_ markdown: String, of object: DatabaseObject) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = object.name + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard keepingPopoverOpen({ panel.runModal() }) == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showError(tr("無法匯出", "Couldn’t export"), error)
        }
    }

    /// Prints the table's document, laid out as the structure document prints.
    @objc func printTable(_ sender: Any?) {
        tableDocument(tr("無法列印", "Couldn’t print")) { [weak self] markdown, object, database in
            self?.printTableDocument(markdown, of: object, in: database)
        }
    }

    private func printTableDocument(_ markdown: String, of object: DatabaseObject, in database: DatabaseConnection) {
        let document = SchemaWindow(databaseName: "\(database.name) \(object.name)", markdown: markdown) { markdown }
        let operation = document.printOperation()
        operation.jobTitle = object.name
        keepingPopoverOpen { _ = operation.run() }
    }

    /// Starts AUTOINCREMENT over, at one past the largest rowid the table has.
    @objc func resetAutoIncrement(_ sender: Any?) {
        guard let database, let object = selected else { return NSSound.beep() }
        do {
            let next = try database.nextFreeAutoIncrement(of: object.name)
            let current = try database.facts(of: object.name)?.nextRowID
            let alert = NSAlert()
            alert.messageText = tr("要重設「\(object.name)」的自動遞增值嗎？", "Reset “\(object.name)”’s AUTOINCREMENT?")
            alert.informativeText = tr("下一筆新資料的編號會從 \(current.map(String.init) ?? "—") 改成 \(next)（目前最大值加 1）。",
                                       "The next new row will get \(next) (one past the largest) instead of \(current.map(String.init) ?? "—").")
            alert.addButton(withTitle: tr("重設", "Reset"))
            alert.addButton(withTitle: tr("取消", "Cancel"))
            guard keepingPopoverOpen({ alert.runModal() }) == .alertFirstButtonReturn else { return }
            let now = try database.setAutoIncrement(of: object.name, to: next)
            loadStructure()
            inform(tr("已重設自動遞增值", "AUTOINCREMENT reset"),
                   tr("下一個自動遞增值：\(now.map(String.init) ?? "—")", "Next AUTOINCREMENT: \(now.map(String.init) ?? "—")"))
        } catch {
            showError(tr("無法重設自動遞增值", "Couldn’t reset AUTOINCREMENT"), error)
        }
    }

    /// Sets AUTOINCREMENT to a value of one's own; SQLite won't go below one past the largest rowid.
    @objc func setAutoIncrement(_ sender: Any?) {
        guard let database, let object = selected else { return NSSound.beep() }
        do {
            let lowest = try database.nextFreeAutoIncrement(of: object.name)
            let current = try database.facts(of: object.name)?.nextRowID
            let field = NSTextField(string: String(current ?? lowest))
            field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
            let alert = NSAlert()
            alert.messageText = tr("設定「\(object.name)」的自動遞增值", "Set “\(object.name)”’s AUTOINCREMENT")
            alert.informativeText = tr("下一筆新資料會用這個編號。不能小於目前最大值加 1（\(lowest)），設得比較小時，SQLite 會改用 \(lowest)。",
                                       "The next new row gets this number. It can’t be below one past the largest (\(lowest)); SQLite uses \(lowest) for anything smaller.")
            alert.accessoryView = field
            alert.addButton(withTitle: tr("設定", "Set"))
            alert.addButton(withTitle: tr("取消", "Cancel"))
            alert.window.initialFirstResponder = field
            while keepingPopoverOpen({ alert.runModal() }) == .alertFirstButtonReturn {
                guard let value = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), value > 0 else {
                    NSSound.beep()
                    continue
                }
                let now = try database.setAutoIncrement(of: object.name, to: value)
                loadStructure()
                inform(tr("已設定自動遞增值", "AUTOINCREMENT set"),
                       tr("下一個自動遞增值：\(now.map(String.init) ?? "—")", "Next AUTOINCREMENT: \(now.map(String.init) ?? "—")"))
                return
            }
        } catch {
            showError(tr("無法設定自動遞增值", "Couldn’t set AUTOINCREMENT"), error)
        }
    }

    // MARK: - SQL tab

    /// Writes the Data tab's table, filter and sort into the SQL tab as a SELECT, unless the SQL
    /// there is someone's own. With no table chosen yet, it starts from the first.
    /// What ends the SELECT written to match the Data tab, to keep the SQL tab quick; exporting
    /// it takes it off.
    private static let matchingLimit = "\nLIMIT 100;"

    private func matchQueryToData() {
        guard let object = selected ?? objects.first,
              editor.string.isEmpty || editor.string == matchingSQL else { return }
        let list = object == selected ? shownColumns.map { $0.map(Database.quote).joined(separator: ", ") } : nil
        var sql = "SELECT \(list ?? "*") FROM \(Database.quote(object.name))"
        if object == selected, let filter = filterBar.condition {
            sql += "\nWHERE " + Database.inline(filter.bindings, into: filter.sql)
        }
        if object == selected, let sort {
            sql += "\nORDER BY \(Database.quote(sort.column)) \(sort.ascending ? "ASC" : "DESC")"
        }
        sql += Self.matchingLimit
        guard sql != editor.string else { return }
        editor.string = sql
        runState = .changed
        matchingSQL = sql
        highlightSQL()
    }

    @objc func runQuery(_ sender: Any?) {
        guard database != nil else { return NSSound.beep() }
        tab = .query
        let selection = editor.selectedRange()
        let sql = selection.length > 0 ? (editor.string as NSString).substring(with: selection) : editor.string
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return NSSound.beep() }
        runState = .running
        runsPending += 1
        let start = Date()
        perform(tr("正在執行 SQL…", "Running the SQL…"), rows: true, cancellable: true) { database in
            try database.run(sql)
        } then: { [weak self] result in
            guard let self else { return }
            self.runsPending -= 1
            if self.runsPending == 0 { self.runState = .done }
            let time = String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)
            switch result {
            case .success(let result):
                self.queryGrid.show(result)
                if result.columns.isEmpty {
                    self.showStatus(tr("已執行，影響 \(result.changes) 列 · \(time)", "Done, \(result.changes) rows changed · \(time)"))
                } else {
                    self.showStatus(tr("\(result.rows.count) 列 · \(time)", "\(result.rows.count) rows · \(time)")
                                    + (result.changes > 0 ? tr("，影響 \(result.changes) 列", ", \(result.changes) changed") : ""))
                }
            case .failure(let error):
                self.showStatus(DatabaseError.wasCancelled(error) ? tr("已取消執行 · \(time)", "Cancelled · \(time)") : error.localizedDescription,
                                error: true)
            }
            // A statement may have changed tables, or the rows of the one selected; one that only reads can't have.
            if Self.mayChange(sql) {
                self.reloadObjects()
                self.loadPage()
                self.loadStructure()
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject === editor else { return }
        highlightSQL()
        runState = .changed
        updateFooter()   // whether there's something to export may have changed
    }

    private func updateRunButton() {
        guard let runButton else { return }
        switch runState {
        case .running:
            runButton.isEnabled = true
            runButton.contentTintColor = .controlAccentColor
        case .changed:
            runButton.isEnabled = database != nil
            runButton.contentTintColor = .labelColor
        case .done:
            runButton.isEnabled = false
            runButton.contentTintColor = .tertiaryLabelColor
        }
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
        columnsButton.isHidden = dataPane.isHidden
        structureView.isHidden = tab != .structure || !hasTable
        tableMenuButton.isHidden = structureView.isHidden
        if !structureView.isHidden, structureStale { refreshStructure() }
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
        reloadRowsButton.isHidden = !paging
        exportRowsButton.isHidden = tab == .query ? queryExport == nil : !paging || total == 0
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
                + (shownColumns.map { shown in
                    let n = dataGrid.result.columns.count - shown.count
                    return tr("，隱藏 \(n) 欄", ", \(n) column\(n == 1 ? "" : "s") hidden")
                } ?? "")
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
        let script = plan.script
        perform(tr("正在匯入 CSV…", "Importing CSV…")) { database in
            do {
                try database.run(script)
            } catch {
                _ = try? database.run("ROLLBACK")   // on this Mac the transaction is still open; over SSH it's gone
                throw error
            }
        } then: { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                return self.showError(tr("無法匯入，資料表沒有變更", "Couldn’t import; the table is unchanged"), error)
            }
            // Show the table it went into, with its new rows.
            if let row = self.objects.firstIndex(of: object), self.sidebar.selectedRow != row {
                self.sidebar.selectRowIndexes([row], byExtendingSelection: false)
            }
            self.tab = .data
            self.refresh(nil)
            self.showNotice(tr("已匯入 \(plan.rows.count) 列", "Imported \(plan.rows.count) row\(plan.rows.count == 1 ? "" : "s")"))
        }
    }

    /// Exports the query's results on the SQL tab, or the whole selected table otherwise.
    @objc func exportCSV(_ sender: Any?) {
        guard database != nil else { return NSSound.beep() }
        let shown = tab == .query ? queryGrid.result : nil
        let table = tab == .query ? nil : selected
        guard shown.map({ !$0.columns.isEmpty }) ?? (table != nil) else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (table?.name ?? tr("查詢結果", "Query Results")) + ".csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard keepingPopoverOpen({ panel.runModal() }) == .OK, let url = panel.url else { return }
        export(to: url) { database in
            try shown ?? database.run("SELECT * FROM \(Database.quote(table!.name))")
        }
    }

    /// Reads rows off the main thread and writes them to `url` as CSV, counting them as they
    /// come; then says how many went, or that it was cancelled.
    private func export(to url: URL, _ rows: @escaping (DatabaseConnection) throws -> ResultSet) {
        perform(tr("正在匯出 CSV…", "Exporting CSV…"), rows: true, cancellable: true) { database in
            let result = try rows(database)
            try CSV.data(result).write(to: url, options: .atomic)
            return result.rows.count
        } then: { [weak self] result in
            switch result {
            case .success(let count):
                self?.showNotice(tr("已匯出 \(count.formatted()) 列到「\(url.lastPathComponent)」",
                                    "Exported \(count.formatted()) row\(count == 1 ? "" : "s") to “\(url.lastPathComponent)”"))
            case .failure(let error) where DatabaseError.wasCancelled(error):
                self?.showNotice(tr("已取消匯出", "Export cancelled"))
            case .failure(let error):
                self?.showError(tr("無法匯出", "Couldn’t export"), error)
            }
        }
    }

    /// The SELECT for everything the Data tab shows, not just the page: its filter, its sort and
    /// the columns showing.
    var dataQuery: (sql: String, bindings: [Value])? {
        guard let object = selected else { return nil }
        let list = shownColumns.map { $0.map(Database.quote).joined(separator: ", ") } ?? "*"
        var sql = "SELECT \(list) FROM \(Database.quote(object.name))"
        let filter = filterBar.condition
        if let filter { sql += " WHERE " + filter.sql }
        if let sort { sql += " ORDER BY \(Database.quote(sort.column)) \(sort.ascending ? "ASC" : "DESC")" }
        return (sql, filter?.bindings ?? [])
    }

    /// Exports what the Data tab shows, in full: every row the filter lets through, in its sort
    /// and the columns showing, rather than the page of 200.
    @objc func exportRows(_ sender: Any?) {
        if tab == .query { return exportQuery() }
        guard database != nil, let object = selected, let query = dataQuery else { return NSSound.beep() }
        let filter = filterBar.condition

        let panel = NSSavePanel()
        panel.nameFieldStringValue = object.name + (filter != nil ? tr("（已篩選）", " (filtered)") : "") + ".csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard keepingPopoverOpen({ panel.runModal() }) == .OK, let url = panel.url else { return }
        export(to: url) { database in try database.run(query.sql, query.bindings) }
    }

    /// What the SQL tab's export button writes: the SELECT written to match the Data tab, run
    /// again without its LIMIT; or else the results showing, as they are. Someone's own SQL isn't
    /// run again for it, since it may change data.
    private enum QueryExport {
        case matching(sql: String)
        case results(ResultSet)
    }

    private var queryExport: QueryExport? {
        guard database != nil else { return nil }
        if let sql = matchingSQL, editor.string == sql, sql.hasSuffix(Self.matchingLimit) {
            return .matching(sql: String(sql.dropLast(Self.matchingLimit.count)))
        }
        return queryGrid.result.columns.isEmpty ? nil : .results(queryGrid.result)
    }

    /// The rows the SQL tab's export writes.
    func queryExportResult() throws -> ResultSet? {
        guard let database, let export = queryExport else { return nil }
        switch export {
        case .matching(let sql): return try database.run(sql)
        case .results(let shown): return shown
        }
    }

    private func exportQuery() {
        guard database != nil, let export = queryExport else { return NSSound.beep() }
        let panel = NSSavePanel()
        if case .matching = export, let object = selected {
            panel.nameFieldStringValue = object.name + (filterBar.condition != nil ? tr("（已篩選）", " (filtered)") : "") + ".csv"
        } else {
            panel.nameFieldStringValue = tr("查詢結果", "Query Results") + ".csv"
        }
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard keepingPopoverOpen({ panel.runModal() }) == .OK, let url = panel.url else { return }
        self.export(to: url) { database in
            switch export {
            case .matching(let sql): return try database.run(sql)
            case .results(let shown): return shown
            }
        }
    }

    // MARK: - Structure document

    private var schemaWindows: [SchemaWindow] = []

    /// Writes the structure of every table and view as Markdown and shows it in its own window.
    @objc func showSchemaDocument(_ sender: Any?) {
        guard database != nil else { return NSSound.beep() }
        perform(tr("正在產生結構文件…", "Writing the structure document…"), cancellable: true) { database in
            (database, try SchemaDocument.markdown(for: database))
        } then: { [weak self] result in
            switch result {
            case .success(let (database, markdown)): self?.showSchemaDocument(markdown, of: database)
            case .failure(let error): self?.showError(tr("無法製作結構文件", "Couldn’t make the structure document"), error)
            }
        }
    }

    private func showSchemaDocument(_ markdown: String, of database: DatabaseConnection) {
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
            // While a statement runs, keys do nothing here but Esc, which cancels it.
            if let self, self.busyOverlay.isShowing, event.window === self.view.window {
                if event.keyCode == 53 { self.busyOverlay.cancel(nil) }
                return nil
            }
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
        add(menu, tr("將目前的資料庫加入常用資料庫…", "Add This Database to Favorites…"), #selector(addToFavorites(_:)), key: "d")
        add(menu, tr("管理常用資料庫…", "Manage Favorite Databases…"), #selector(manageFavorites(_:)))
        add(menu, tr("關閉標籤頁", "Close Tab"), #selector(closeDatabase(_:)), key: "w").keyEquivalentModifierMask = [.command, .option]
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
        if busyOverlay.isShowing { return false }
        switch menuItem.action {
        case #selector(refresh(_:)), #selector(exportCSV(_:)), #selector(showDatabaseInfo(_:)), #selector(showSchemaDocument(_:)), #selector(runQuery(_:)), #selector(showQueryTab(_:)),
             #selector(addToFavorites(_:)):
            return database != nil
        case #selector(showDataTab(_:)), #selector(showStructureTab(_:)), #selector(toggleFilter(_:)), #selector(showColumnsMenu(_:)):
            return selected != nil
        case #selector(nextTab(_:)), #selector(previousTab(_:)):
            return sessions.count > 1
        case #selector(closeDatabase(_:)):
            return database != nil
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
        case #selector(importCSV(_:)), #selector(emptyTable(_:)):
            return canChangeSchema && actedOn?.kind == .table
        case #selector(deleteTable(_:)):
            return canChangeSchema && actedOn != nil
        default:
            return true
        }
    }
}

/// A tab in the strip under the toolbar: its title and close button on a rounded background,
/// tinted for the tab showing, as wide as its title needs up to a limit.
private final class TabChip: NSView {
    private let active: Bool

    init(views: [NSView], active: Bool) {
        self.active = active
        super.init(frame: .zero)
        let row = NSStackView(views: views)
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.init(200), for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        (active ? NSColor.controlAccentColor.withAlphaComponent(0.25) : NSColor.quaternaryLabelColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    /// A click on the tab shows it.
    var onSelect: (() -> Void)?
    /// The tab dragged from one place among the tabs to another, by their order in the strip.
    var onMove: ((_ from: Int, _ to: Int) -> Void)?

    /// Follows the mouse: a click picks the tab; once it moves a few points, the tab is dragged
    /// along the strip, the others making way as it passes their middles, and dropped where it is.
    override func mouseDown(with event: NSEvent) {
        guard let strip = superview as? NSStackView, let window else { return }
        let tabs = { strip.arrangedSubviews.filter { $0 is TabChip } }
        guard let from = tabs().firstIndex(of: self) else { return }
        let start = event.locationInWindow
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            if !dragging {
                guard abs(next.locationInWindow.x - start.x) > 4 else { continue }
                dragging = true
                alphaValue = 0.7
                NSCursor.closedHand.push()
            }
            let x = strip.convert(next.locationInWindow, from: nil).x
            let others = tabs().filter { $0 !== self }
            let target = others.firstIndex { x < $0.frame.midX } ?? others.count
            if tabs().firstIndex(of: self) != target {
                strip.removeArrangedSubview(self)
                strip.insertArrangedSubview(self, at: target)   // the tabs come first in the strip
                strip.layoutSubtreeIfNeeded()
            }
        }
        guard dragging else { return onSelect?() ?? () }
        alphaValue = 1
        NSCursor.pop()
        onMove?(from, tabs().firstIndex(of: self) ?? from)
    }
}
