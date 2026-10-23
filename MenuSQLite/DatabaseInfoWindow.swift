import AppKit

/// A window about the open database: where it is, how big, whether it can be changed, and how
/// SQLite keeps it; with auto_vacuum to set and VACUUM to run, which gives unused space back.
final class DatabaseInfoWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let database: DatabaseConnection
    /// Called after the database has been changed (VACUUM rebuilds it), to refresh what shows.
    var onChange: (() -> Void)?

    private let grid = NSGridView()
    private let autoVacuum = NSPopUpButton()
    private let vacuumButton = NSButton()
    private let message = NSTextField(wrappingLabelWithString: "")

    /// SQLite's auto_vacuum settings, by their number.
    private static let autoVacuumModes = ["NONE", "FULL", "INCREMENTAL"]

    init(database: DatabaseConnection) {
        self.database = database
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = tr("資料庫資訊：\(database.name)", "Database Info: \(database.name)")
        panel.delegate = self
        build()
        reload()
    }

    var window: NSWindow { panel }

    /// Shows the window until it's closed.
    func run() {
        panel.center()
        NSApp.runModal(for: panel)
    }

    // MARK: Layout

    private func build() {
        grid.columnSpacing = 12
        grid.rowSpacing = 6

        let maintenance = NSTextField(labelWithString: tr("維護", "Maintenance"))
        maintenance.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        autoVacuum.addItems(withTitles: Self.autoVacuumModes)
        autoVacuum.target = self
        autoVacuum.action = #selector(autoVacuumChanged(_:))
        let autoVacuumHint = NSTextField(wrappingLabelWithString: tr(
            "NONE：刪除資料後檔案不會變小，空間留著給之後的資料用。FULL：每次交易結束就把空出來的空間還給系統。INCREMENTAL：先記下空出來的空間，等執行 incremental_vacuum 時才歸還。變更後要執行一次 VACUUM 才會生效。",
            "NONE: the file doesn’t shrink when data is deleted; the space is kept for new data. FULL: space freed is given back at the end of each transaction. INCREMENTAL: freed space is noted and given back when incremental_vacuum runs. A change takes effect after a VACUUM."))
        autoVacuumHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        autoVacuumHint.textColor = .secondaryLabelColor
        let autoVacuumRow = NSStackView(views: [NSTextField(labelWithString: "auto_vacuum"), autoVacuum])

        vacuumButton.title = tr("壓縮資料庫（VACUUM）", "Compact Database (VACUUM)")
        vacuumButton.bezelStyle = .rounded
        vacuumButton.target = self
        vacuumButton.action = #selector(vacuum(_:))
        let vacuumHint = NSTextField(wrappingLabelWithString: tr(
            "重新整理整個資料庫檔案，把未使用的空間還給系統並減少零碎。需要大約資料庫大小的暫存空間，大的資料庫要花一點時間。",
            "Rebuilds the whole file, giving unused space back and undoing fragmentation. It needs about the database’s size in temporary space, and takes a while for a large database."))
        vacuumHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        vacuumHint.textColor = .secondaryLabelColor

        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let close = NSButton(title: tr("關閉", "Close"), target: self, action: #selector(closeWindow(_:)))
        close.keyEquivalent = "\r"
        let closeRow = NSStackView(views: [NSView(), close])
        let actions = NSStackView(views: [vacuumButton])

        let line = NSBox()
        line.boxType = .separator
        let stack = NSStackView(views: [grid, line, maintenance, autoVacuumRow, autoVacuumHint, actions, vacuumHint, message, closeRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: grid)
        stack.setCustomSpacing(14, after: line)
        stack.setCustomSpacing(14, after: autoVacuumHint)
        stack.setCustomSpacing(14, after: message)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        for view in [line, autoVacuumHint, vacuumHint, message, closeRow] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            panel.contentView!.widthAnchor.constraint(equalToConstant: 520),
        ])
    }

    // MARK: Facts

    private struct Facts {
        var pageSize = 0, pageCount = 0, freePages = 0, autoVacuum = 0
        var journalMode = "", encoding = "", version = ""
        var dataSize: Int { pageSize * pageCount }
        var freeSize: Int { pageSize * freePages }
    }

    private func facts() throws -> Facts {
        func number(_ pragma: String) throws -> Int {
            guard case .integer(let n)? = try database.run("PRAGMA \(pragma)").rows.first?.first else { return 0 }
            return Int(n)
        }
        func text(_ sql: String) throws -> String { try database.run(sql).rows.first?.first?.display ?? "" }
        return Facts(pageSize: try number("page_size"), pageCount: try number("page_count"),
                     freePages: try number("freelist_count"), autoVacuum: try number("auto_vacuum"),
                     journalMode: try text("PRAGMA journal_mode").uppercased(), encoding: try text("PRAGMA encoding"),
                     version: try text("SELECT sqlite_version()"))
    }

    /// The file's size on this Mac, with its -wal file if there is one; over SSH, SQLite's own
    /// count of its pages, which is the main file.
    private func fileSize(_ facts: Facts) -> (size: Int, note: String?) {
        guard let local = database as? Database else { return (facts.dataSize, nil) }
        func size(_ path: String) -> Int { (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0 }
        let main = size(local.url.path), wal = size(local.url.path + "-wal")
        return (main + wal, wal > 0 ? tr("含 -wal 檔 \(Self.bytes(wal))", "with \(Self.bytes(wal)) in its -wal file") : nil)
    }

    /// When the file was made and last changed. On this Mac, a newer -wal file counts as the
    /// change (that's where recent writes are until they're moved into the file).
    private func fileDates() -> (created: Date?, modified: Date?) {
        if let remote = database as? RemoteDatabase { return remote.fileDates() }
        guard let local = database as? Database else { return (nil, nil) }
        func attributes(_ path: String) -> [FileAttributeKey: Any] { (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:] }
        let main = attributes(local.url.path), wal = attributes(local.url.path + "-wal")
        let modified = [main[.modificationDate], wal[.modificationDate]].compactMap { $0 as? Date }.max()
        return (main[.creationDate] as? Date, modified)
    }

    private static func date(_ date: Date?) -> String {
        guard let date else { return tr("不詳", "Unknown") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Language.current == .en ? "en_US" : Language.current == .zhHans ? "zh_CN" : "zh_TW")
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false   // "0 bytes", not "Zero KB"
        return formatter
    }()

    private static func bytes(_ count: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(count))
    }

    private func reload() {
        // Removing a grid's rows leaves their views behind; take those out too.
        for view in grid.subviews { view.removeFromSuperview() }
        for _ in 0..<grid.numberOfRows { grid.removeRow(at: 0) }
        func row(_ title: String, _ value: String, selectable: Bool = false) {
            let label = NSTextField(labelWithString: title)
            label.textColor = .secondaryLabelColor
            let field = NSTextField(wrappingLabelWithString: value)
            field.isSelectable = selectable
            field.preferredMaxLayoutWidth = 360
            grid.addRow(with: [label, field])
        }
        let remote = database is RemoteDatabase
        let path = remote ? String(database.location.drop { $0 != ":" }.dropFirst()) : database.location
        row(tr("檔名", "Name"), database.name, selectable: true)
        if remote { row(tr("伺服器", "Server"), String(database.location.prefix { $0 != ":" }), selectable: true) }
        row(tr("路徑", "Path"), (path as NSString).deletingLastPathComponent, selectable: true)
        row(tr("唯讀", "Read-Only"), database.readOnly ? tr("是（沒有寫入權限）", "Yes (no permission to write)") : tr("否", "No"))
        do {
            let facts = try facts()
            let file = fileSize(facts)
            row(tr("大小", "Size"), Self.bytes(file.size) + (file.note.map { tr("（\($0)）", " (\($0))") } ?? ""))
            let dates = fileDates()
            row(tr("建立日期", "Created"), Self.date(dates.created))
            row(tr("最後更動", "Last Changed"), Self.date(dates.modified))
            row(tr("未使用的空間", "Unused Space"), Self.bytes(facts.freeSize)
                + tr("（\(facts.freePages) 頁，VACUUM 可以回收）", " (\(facts.freePages) pages, which VACUUM gives back)"))
            row(tr("頁面", "Pages"), tr("\(facts.pageCount) 頁，每頁 \(Self.bytes(facts.pageSize))", "\(facts.pageCount) of \(Self.bytes(facts.pageSize)) each"))
            row(tr("日誌模式", "Journal Mode"), facts.journalMode)
            row(tr("文字編碼", "Text Encoding"), facts.encoding)
            row(tr("SQLite 版本", "SQLite Version"), facts.version + (remote ? tr("（伺服器上的 sqlite3）", " (sqlite3 on the server)") : ""))
            autoVacuum.selectItem(at: min(max(facts.autoVacuum, 0), 2))
        } catch {
            row(tr("錯誤", "Error"), error.localizedDescription)
        }
        grid.column(at: 0).xPlacement = .trailing
        autoVacuum.isEnabled = !database.readOnly
        vacuumButton.isEnabled = !database.readOnly
        if database.readOnly, message.stringValue.isEmpty {
            show(tr("資料庫是唯讀的，無法變更 auto_vacuum 或壓縮。", "The database is read-only, so auto_vacuum can’t change and it can’t be compacted."), error: false)
        }
    }

    private func show(_ text: String, error: Bool) {
        message.stringValue = text
        message.textColor = error ? .systemRed : .secondaryLabelColor
    }

    // MARK: Actions

    @objc private func autoVacuumChanged(_ sender: NSPopUpButton) {
        let mode = Self.autoVacuumModes[sender.indexOfSelectedItem]
        let alert = NSAlert()
        alert.messageText = tr("要把 auto_vacuum 改成 \(mode) 嗎？", "Change auto_vacuum to \(mode)?")
        alert.informativeText = tr("變更後會立刻執行 VACUUM 重整整個資料庫，設定才會生效。大的資料庫要花一點時間。",
                                   "VACUUM then rebuilds the whole database, which the change needs to take effect. It takes a while for a large database.")
        alert.addButton(withTitle: tr("變更並壓縮", "Change and Compact"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return reload() }
        run("PRAGMA auto_vacuum = \(sender.indexOfSelectedItem); VACUUM;",
            done: tr("auto_vacuum 已改成 \(mode)", "auto_vacuum is now \(mode)"))
    }

    @objc private func vacuum(_ sender: Any?) {
        run("VACUUM;", done: tr("已壓縮", "Compacted"))
    }

    /// Runs SQL that rebuilds the database, saying how the size changed.
    private func run(_ sql: String, done: String) {
        let before = (try? facts()).map { fileSize($0).size }
        show(tr("正在壓縮…", "Compacting…"), error: false)
        vacuumButton.isEnabled = false
        autoVacuum.isEnabled = false
        panel.display()   // VACUUM holds this thread; show the message first
        do {
            try database.run(sql)
            reload()
            let after = (try? facts()).map { fileSize($0).size }
            if let before, let after {
                show(done + tr("：\(Self.bytes(before)) → \(Self.bytes(after))", ": \(Self.bytes(before)) → \(Self.bytes(after))"), error: false)
            } else {
                show(done, error: false)
            }
            onChange?()
        } catch {
            reload()
            show(tr("無法壓縮：", "Couldn’t compact: ") + error.localizedDescription, error: true)
        }
    }

    @objc private func closeWindow(_ sender: Any?) {
        panel.close()
    }

    /// Closed by its button or the title bar's: either way the modal session ends.
    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}
