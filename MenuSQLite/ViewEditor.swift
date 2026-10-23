import AppKit

/// A window for writing a new view or changing one: its name, optional column names, and the
/// SELECT that defines it, with a preview of the rows it gives. Saving first runs the SELECT,
/// because SQLite accepts a view over a table that doesn't exist and fails only when it's read.
final class ViewEditor: NSObject, NSTextViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let panel: NSPanel
    private let database: DatabaseConnection
    private let original: String?
    private let nameField = NSTextField()
    private let columnsField = NSTextField()
    private let editorView = NSTextView.scrollableTextView()
    private var editor: NSTextView { editorView.documentView as! NSTextView }
    private let results = Grid()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var saveButton: NSButton!

    /// The SQL to run, once the window closes with Save.
    private(set) var sql: String?
    var viewName: String { nameField.stringValue.trimmingCharacters(in: .whitespaces) }
    var window: NSWindow { panel }

    /// For a new view, `original` is nil; otherwise the view's name, whose definition is loaded.
    init(database: DatabaseConnection, original: String?) throws {
        self.database = database
        self.original = original
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = original.map { tr("編輯視圖「\($0)」", "Edit View “\($0)”") } ?? tr("新增視圖", "New View")
        panel.minSize = NSSize(width: 520, height: 440)
        build()
        if let original {
            let parts = ViewDesign.parts(of: try database.createStatement(of: original) ?? "")
            nameField.stringValue = original
            columnsField.stringValue = parts.columns
            editor.string = parts.select
            let triggers = try database.run("SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?", [.text(original)]).rows
            if !triggers.isEmpty {
                show(tr("儲存時會重建視圖，觸發程序 \(triggers.map { $0[0].display }.joined(separator: "、")) 會被刪除。",
                        "Saving rebuilds the view, deleting the trigger\(triggers.count == 1 ? "" : "s") \(triggers.map { $0[0].display }.joined(separator: ", "))."),
                     error: false)
            }
        } else {
            editor.string = "SELECT\n  \nFROM "
        }
        highlight()
    }

    /// Shows the window until it's closed; true if Save was clicked.
    func run() -> Bool {
        panel.center()
        panel.makeFirstResponder(original == nil ? nameField : editor)
        return NSApp.runModal(for: panel) == .OK
    }

    private func build() {
        nameField.placeholderString = tr("視圖名稱", "View name")
        nameField.delegate = self
        columnsField.placeholderString = tr("例如 name, total（選填，不填就用 SELECT 的欄位名稱）", "e.g. name, total (optional; the SELECT's names otherwise)")
        let fields = NSGridView(views: [
            [NSTextField(labelWithString: tr("名稱", "Name")), nameField],
            [NSTextField(labelWithString: tr("欄位名稱", "Column Names")), columnsField],
        ])
        fields.column(at: 0).xPlacement = .trailing
        fields.rowAlignment = .firstBaseline

        editor.delegate = self
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editorView.borderType = .bezelBorder
        editorView.hasVerticalScroller = true
        editorView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let previewButton = NSButton(title: tr("預覽結果", "Preview"), target: self, action: #selector(preview(_:)))
        previewButton.keyEquivalent = "\r"
        previewButton.keyEquivalentModifierMask = .command
        let previewBar = NSStackView(views: [NSTextField(labelWithString: "AS"), NSView(), previewButton])
        results.scrollView.borderType = .bezelBorder
        results.scrollView.heightAnchor.constraint(equalToConstant: 150).isActive = true
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.isHidden = true

        saveButton = NSButton(title: original == nil ? tr("建立", "Create") : tr("儲存", "Save"), target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        let cancel = NSButton(title: tr("取消", "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [NSView(), cancel, saveButton])

        let stack = NSStackView(views: [fields, previewBar, editorView, message, results.scrollView, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        for view in [fields, previewBar, editorView, message, results.scrollView, actions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        editorView.setContentHuggingPriority(.init(1), for: .vertical)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
        ])
    }

    func textDidChange(_ notification: Notification) { highlight() }

    private func highlight() {
        guard let storage = editor.textStorage else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: storage.length))
        SyntaxHighlighter.highlight(storage, language: "sql")
        storage.endEditing()
    }

    private func show(_ text: String, error: Bool) {
        message.stringValue = text
        message.textColor = error ? .systemRed : .systemOrange
        message.isHidden = text.isEmpty
    }

    /// Runs the SELECT and shows its first rows; false, with the error shown, if it fails.
    @discardableResult
    @objc private func preview(_ sender: Any?) -> Bool {
        do {
            let result = try ViewDesign.preview(editor.string, in: database)
            results.show(result)
            show(result.rows.isEmpty ? tr("查詢沒有傳回資料列。", "The query returns no rows.") : "", error: false)
            return true
        } catch {
            results.show(ResultSet())
            show(error.localizedDescription, error: true)
            return false
        }
    }

    @objc private func save(_ sender: Any?) {
        panel.makeFirstResponder(nil)
        guard !viewName.isEmpty else { show(tr("請輸入視圖名稱。", "Enter a name for the view."), error: true); return NSSound.beep() }
        guard !ViewDesign.trimmed(editor.string).isEmpty else { show(tr("請輸入 SELECT 語句。", "Enter a SELECT statement."), error: true); return NSSound.beep() }
        guard preview(nil) else { return NSSound.beep() }
        sql = ViewDesign.sql(name: viewName, columns: columnsField.stringValue, select: editor.string, replacing: original)
        NSApp.stopModal(withCode: .OK)
        panel.orderOut(nil)
    }

    /// The title bar's close button: the same as Cancel.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel(sender)
        return false
    }

    @objc private func cancel(_ sender: Any?) {
        sql = nil
        NSApp.stopModal(withCode: .cancel)
        panel.orderOut(nil)
    }
}
