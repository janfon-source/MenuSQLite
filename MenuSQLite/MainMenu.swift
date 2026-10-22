import AppKit

/// The main menu is never shown (accessory app), but its key equivalents still work while the
/// popover is key: ⌘O, ⌘C, ⌘↩ and the rest. Rebuilt when the language changes.
enum MainMenu {
    static func build(main controller: MainViewController) -> NSMenu {
        let main = NSMenu()

        let app = submenu(in: main, tr("隨手庫", "MenuSQLite"))
        app.addItem(withTitle: tr("結束隨手庫", "Quit MenuSQLite"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(in: main, tr("檔案", "File"))
        add(file, tr("開啟資料庫…", "Open Database…"), #selector(MainViewController.openDocument(_:)), "o", target: controller)
        add(file, tr("新增資料庫…", "New Database…"), #selector(MainViewController.newDocument(_:)), "n", target: controller)
        add(file, tr("連線到伺服器上的資料庫…", "Open a Database on a Server…"), #selector(MainViewController.connectRemote(_:)), "O", target: controller)
        add(file, tr("重新整理", "Refresh"), #selector(MainViewController.refresh(_:)), "r", target: controller)
        file.addItem(.separator())
        add(file, tr("新增資料表…", "New Table…"), #selector(MainViewController.newTable(_:)), "n", target: controller)
            .keyEquivalentModifierMask = [.command, .option]
        add(file, tr("新增視圖…", "New View…"), #selector(MainViewController.newView(_:)), "N", target: controller)
            .keyEquivalentModifierMask = [.command, .option, .shift]
        add(file, tr("編輯資料表或視圖…", "Edit Table or View…"), #selector(MainViewController.editTable(_:)), "e", target: controller)
            .keyEquivalentModifierMask = [.command, .option]
        add(file, tr("匯出 CSV…", "Export CSV…"), #selector(MainViewController.exportCSV(_:)), "E", target: controller)
        add(file, tr("結構文件（Markdown）…", "Structure Document (Markdown)…"), #selector(MainViewController.showSchemaDocument(_:)), "D", target: controller)
        add(file, tr("關閉視窗", "Close Window"), #selector(MainViewController.closePopover(_:)), "w", target: controller)

        let edit = submenu(in: main, tr("編輯", "Edit"))
        add(edit, tr("還原", "Undo"), Selector(("undo:")), "z")
        add(edit, tr("重做", "Redo"), Selector(("redo:")), "Z")
        edit.addItem(.separator())
        add(edit, tr("剪下", "Cut"), #selector(NSText.cut(_:)), "x")
        add(edit, tr("拷貝", "Copy"), #selector(NSText.copy(_:)), "c")
        add(edit, tr("貼上", "Paste"), #selector(NSText.paste(_:)), "v")
        add(edit, tr("全選", "Select All"), #selector(NSText.selectAll(_:)), "a")
        let find = add(edit, tr("尋找…", "Find…"), #selector(NSTextView.performFindPanelAction(_:)), "f")
        find.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)

        let view = submenu(in: main, tr("顯示方式", "View"))
        add(view, tr("資料", "Data"), #selector(MainViewController.showDataTab(_:)), "1", target: controller)
        add(view, tr("結構", "Structure"), #selector(MainViewController.showStructureTab(_:)), "2", target: controller)
        add(view, "SQL", #selector(MainViewController.showQueryTab(_:)), "3", target: controller)

        let query = submenu(in: main, tr("查詢", "Query"))
        add(query, tr("執行", "Run"), #selector(MainViewController.runQuery(_:)), "\r", target: controller)
        add(query, tr("新增一列", "Add a Row"), #selector(MainViewController.addRow(_:)), "+", target: controller)
        return main
    }

    private static func submenu(in main: NSMenu, _ title: String) -> NSMenu {
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                            target: AnyObject? = nil) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}
