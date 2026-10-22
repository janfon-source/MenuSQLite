import AppKit
import UniformTypeIdentifiers

/// A window showing a database's structure document as Markdown, which can be touched up before
/// it's saved to a file or opened in the app that opens Markdown files.
final class SchemaWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private let window: NSWindow
    private let textView: NSTextView
    private let status = NSTextField(labelWithString: "")
    private let databaseName: String
    private let regenerate: () throws -> String
    /// Where the document was last saved, while the text is unchanged since.
    private var savedURL: URL?
    var onClose: (() -> Void)?

    /// `regenerate` makes the document again from the database, for the Refresh button.
    init(databaseName: String, markdown: String, regenerate: @escaping () throws -> String) {
        self.databaseName = databaseName
        self.regenerate = regenerate
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        super.init()

        window.title = tr("結構文件：\(databaseName)", "Structure Document: \(databaseName)")
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("SchemaWindow")

        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.delegate = self
        scroll.hasVerticalScroller = true

        let refresh = NSButton(title: tr("重新產生", "Regenerate"), target: self, action: #selector(refresh(_:)))
        let openButton = NSButton(title: tr("用預設 App 開啟", "Open in Default App"), target: self, action: #selector(openInApp(_:)))
        let save = NSButton(title: tr("另存新檔…", "Save As…"), target: self, action: #selector(saveAs(_:)))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [refresh, status, spacer, openButton, save])
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)

        let stack = NSStackView(views: [scroll, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        window.contentView = stack
        show(markdown)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        if !window.setFrameUsingName("SchemaWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    private func show(_ markdown: String) {
        textView.string = markdown
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        highlight()
        savedURL = nil
        status.stringValue = tr("可直接修改內容後再存檔", "You can edit the text before saving")
    }

    func textDidChange(_ notification: Notification) {
        highlight()
        savedURL = nil
    }

    /// Headings bold, SQL in code blocks colored; the rest stays plain Markdown.
    private func highlight() {
        guard let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: storage.length))
        var inCode = false, codeStart = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { line, range, enclosing, _ in
            guard let line else { return }
            if line.hasPrefix("```") {
                if inCode {
                    let code = NSRange(location: codeStart, length: range.location - codeStart)
                    let attributed = NSMutableAttributedString(string: text.substring(with: code), attributes: [.font: font])
                    SyntaxHighlighter.highlight(attributed, language: "sql")
                    attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributed.length)) { color, r, _ in
                        if let color { storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: code.location + r.location, length: r.length)) }
                    }
                } else {
                    codeStart = NSMaxRange(enclosing)
                }
                inCode.toggle()
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            } else if !inCode, line.hasPrefix("#") {
                storage.addAttributes([.font: bold, .foregroundColor: NSColor.controlAccentColor], range: range)
            } else if !inCode, line.hasPrefix("**") || line.hasPrefix("|---") || line.hasPrefix("|:") {
                storage.addAttribute(line.hasPrefix("**") ? .font : .foregroundColor,
                                     value: line.hasPrefix("**") ? bold : NSColor.tertiaryLabelColor, range: range)
            }
        }
        storage.endEditing()
    }

    private var fileName: String {
        let base = (databaseName as NSString).deletingPathExtension
        return tr("\(base) 結構.md", "\(base) structure.md")
    }

    @objc private func refresh(_ sender: Any?) {
        do {
            show(try regenerate())
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    @objc private func saveAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = savedURL?.lastPathComponent ?? fileName
        if let savedURL { panel.directoryURL = savedURL.deletingLastPathComponent() }
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try textView.string.write(to: url, atomically: true, encoding: .utf8)
                savedURL = url
                status.stringValue = tr("已儲存到 \(url.path)", "Saved to \(url.path)")
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// Opens the saved file, or a copy of the text in a temporary folder if it isn't saved as it is.
    @objc private func openInApp(_ sender: Any?) {
        var url = savedURL
        if url == nil {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MenuSQLite", isDirectory: true)
            let file = folder.appendingPathComponent(fileName)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try textView.string.write(to: file, atomically: true, encoding: .utf8)
                url = file
            } catch {
                return NSAlert(error: error).beginSheetModal(for: window)
            }
        }
        if let url, !NSWorkspace.shared.open(url) {
            status.stringValue = tr("找不到可以開啟 Markdown 的 App", "No app opens Markdown files")
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
