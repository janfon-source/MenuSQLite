import AppKit
import UniformTypeIdentifiers

/// A window showing a database's structure document, rendered as Markdown. The Markdown itself
/// is a click away and can be touched up before it's saved to a file or opened in another app.
final class SchemaWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private let window: NSWindow
    /// The Markdown, editable.
    private let sourceScroll = NSTextView.scrollableTextView()
    private var sourceView: NSTextView { sourceScroll.documentView as! NSTextView }
    /// The Markdown as it reads, the way 隨手記 previews it.
    private let previewScroll = NSTextView.scrollableTextView()
    private var previewView: NSTextView { previewScroll.documentView as! NSTextView }
    private let mode = NSSegmentedControl()
    private let status = NSTextField(labelWithString: "")
    private let databaseName: String
    private let regenerate: () throws -> String
    /// Where the document was last saved, while the text is unchanged since.
    private var savedURL: URL?
    /// The preview is out of date with the Markdown, or with the width its tables were sized to.
    private var renderedText: String?
    private var renderedWidth: CGFloat = 0
    private static let fontSize: CGFloat = 13
    var onClose: (() -> Void)?

    /// `regenerate` makes the document again from the database, for the Regenerate button.
    init(databaseName: String, markdown: String, regenerate: @escaping () throws -> String) {
        self.databaseName = databaseName
        self.regenerate = regenerate
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()

        window.title = tr("結構文件：\(databaseName)", "Structure Document: \(databaseName)")
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let source = sourceView
        source.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        source.isRichText = false
        source.allowsUndo = true
        source.usesFindBar = true
        source.isIncrementalSearchingEnabled = true
        source.isAutomaticQuoteSubstitutionEnabled = false
        source.isAutomaticDashSubstitutionEnabled = false
        source.isContinuousSpellCheckingEnabled = false
        source.textContainerInset = NSSize(width: 10, height: 10)
        source.delegate = self
        sourceScroll.hasVerticalScroller = true

        let preview = previewView
        preview.textContainer?.replaceLayoutManager(PreviewLayoutManager())   // draws inline code shading
        preview.isEditable = false
        preview.isSelectable = true
        preview.usesFindBar = true
        preview.isIncrementalSearchingEnabled = true
        preview.textContainerInset = NSSize(width: 16, height: 14)
        preview.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        preview.delegate = self
        previewScroll.hasVerticalScroller = true
        previewScroll.drawsBackground = true
        previewScroll.backgroundColor = .textBackgroundColor
        previewScroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: previewScroll.contentView,
                                               queue: .main) { [weak self] _ in self?.renderIfNeeded() }

        mode.segmentCount = 2
        mode.setLabel(tr("預覽", "Preview"), forSegment: 0)
        mode.setLabel("Markdown", forSegment: 1)
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged(_:))
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
        let bar = NSStackView(views: [mode, refresh, status, spacer, openButton, save])
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)

        let stack = NSStackView(views: [previewScroll, sourceScroll, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        for scroll in [previewScroll, sourceScroll] {
            scroll.setContentHuggingPriority(.init(1), for: .vertical)
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window.contentView = stack
        show(markdown)
        showMode()
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        if !window.setFrameUsingName("SchemaWindow") { window.center() }
        window.setFrameAutosaveName("SchemaWindow")
        window.makeKeyAndOrderFront(nil)
        renderIfNeeded()
    }

    private func show(_ markdown: String) {
        sourceView.string = markdown
        sourceView.setSelectedRange(NSRange(location: 0, length: 0))
        sourceView.scrollToBeginningOfDocument(nil)
        highlight()
        savedURL = nil
        renderedText = nil
        renderIfNeeded()
        previewView.scrollToBeginningOfDocument(nil)
        status.stringValue = ""
    }

    // MARK: Preview and Markdown

    private var showingPreview: Bool { mode.selectedSegment == 0 }

    @objc private func modeChanged(_ sender: Any?) { showMode() }

    private func showMode() {
        previewScroll.isHidden = !showingPreview
        sourceScroll.isHidden = showingPreview
        status.stringValue = showingPreview ? "" : tr("可直接修改內容後再存檔", "You can edit the text before saving")
        renderIfNeeded()
        window.makeFirstResponder(showingPreview ? previewView : sourceView)
    }

    /// Renders the preview when it's showing and its text or width has changed since.
    private func renderIfNeeded() {
        guard showingPreview else { return }
        let width = previewView.bounds.width - previewView.textContainerInset.width * 2
            - (previewView.textContainer?.lineFragmentPadding ?? 0) * 2
        guard renderedText != sourceView.string || (width > 0 && abs(width - renderedWidth) > 1) else { return }
        let origin = previewScroll.contentView.bounds.origin
        renderedText = sourceView.string
        renderedWidth = width
        previewView.textStorage?.setAttributedString(MarkdownRenderer.render(
            sourceView.string, fontSize: Self.fontSize, baseURL: nil, width: width > 0 ? width : nil))
        previewScroll.contentView.scroll(to: origin)
        previewScroll.reflectScrolledClipView(previewScroll.contentView)
    }

    func textDidChange(_ notification: Notification) {
        highlight()
        savedURL = nil
    }

    /// Links in the preview to its own footnotes and headings; other links open as usual.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard textView === previewView, let url = link as? URL, url.scheme == HackMD.anchorScheme, let anchor = url.host,
              let storage = previewView.textStorage else { return false }
        storage.enumerateAttribute(HackMD.anchor, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as? String == anchor {
                previewView.scrollRangeToVisible(range)
                stop.pointee = true
            }
        }
        return true
    }

    /// In the Markdown: headings bold, SQL in code blocks colored, the rest plain.
    private func highlight() {
        guard let storage = sourceView.textStorage else { return }
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
            } else if !inCode, line.hasPrefix("**") {
                storage.addAttribute(.font, value: bold, range: range)
            } else if !inCode, line.hasPrefix("|-") || line.hasPrefix("|:") {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
            }
        }
        storage.endEditing()
    }

    // MARK: Saving and opening

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
                try sourceView.string.write(to: url, atomically: true, encoding: .utf8)
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
                try sourceView.string.write(to: file, atomically: true, encoding: .utf8)
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
