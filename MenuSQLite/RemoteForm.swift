import AppKit

/// The fields for opening a database on a server. The server field lists the Hosts in
/// ~/.ssh/config; picking one (or typing its name) fills in its port and key from the config,
/// and the database path last used there.
final class RemoteForm: NSObject, NSComboBoxDelegate, NSTextFieldDelegate {
    let view: NSGridView
    private let host = NSComboBox()
    private let port: NSTextField
    private let path: NSTextField
    private let key: NSTextField
    private let resolved = NSTextField(labelWithString: "")
    private let hosts: [SSHHost]
    /// The path last used on a server, from the recent list.
    private let lastPath: (String) -> String?

    var firstField: NSView { host.stringValue.isEmpty ? host : path }

    /// Whether the fields can be used; off greys them out, for a form that's shown but not chosen.
    var isEnabled = true {
        didSet {
            for control in [host, port, path, key] as [NSControl] { control.isEnabled = isEnabled }
            for case let label as NSTextField in view.subviews where !label.isEditable && label !== resolved {
                label.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
            }
        }
    }

    init(start: RemoteLocation?, hosts: [SSHHost] = SSHConfig.hosts(), lastPath: @escaping (String) -> String?) {
        self.hosts = hosts
        self.lastPath = lastPath
        func field(_ value: String, _ placeholder: String) -> NSTextField {
            let field = NSTextField(string: value)
            field.placeholderString = placeholder
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
            return field
        }
        port = field(start?.port.map(String.init) ?? "", tr("22（選填）", "22 (optional)"))
        path = field(start?.path ?? "", tr("/var/data/app.sqlite 或 ~/app.db", "/var/data/app.sqlite or ~/app.db"))
        key = field(start?.identity ?? "", tr("~/.ssh/id_ed25519（選填）", "~/.ssh/id_ed25519 (optional)"))
        resolved.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        resolved.textColor = .secondaryLabelColor
        view = NSGridView(views: [
            [NSTextField(labelWithString: tr("主機", "Server")), host],
            [NSGridCell.emptyContentView, resolved],
            [NSTextField(labelWithString: tr("連接埠", "Port")), port],
            [NSTextField(labelWithString: tr("資料庫路徑", "Database Path")), path],
            [NSTextField(labelWithString: tr("私鑰", "Private Key")), key],
        ])
        super.init()

        host.stringValue = start?.destination ?? ""
        host.placeholderString = hosts.isEmpty ? tr("user@example.com", "user@example.com")
                                               : tr("從 ~/.ssh/config 選擇，或輸入 user@host", "Pick from ~/.ssh/config, or type user@host")
        host.addItems(withObjectValues: hosts.map(\.alias))
        host.numberOfVisibleItems = 12
        host.completes = true
        host.delegate = self
        host.widthAnchor.constraint(equalToConstant: 300).isActive = true
        view.column(at: 0).xPlacement = .trailing
        view.rowAlignment = .firstBaseline
        view.row(at: 1).topPadding = -4
        showResolved()
        view.frame.size = view.fittingSize
    }

    /// What was entered, or nil if the server or path is missing.
    var location: RemoteLocation? {
        func value(_ field: NSTextField) -> String { field.stringValue.trimmingCharacters(in: .whitespaces) }
        guard !value(host).isEmpty, !value(path).isEmpty else { return nil }
        return RemoteLocation(destination: value(host), port: Int(value(port)), path: value(path),
                              identity: value(key).isEmpty ? nil : value(key))
    }

    // MARK: Filling in from the config

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard host.indexOfSelectedItem >= 0 else { return }
        fill(from: hosts[host.indexOfSelectedItem])
    }

    /// A Host typed in full, rather than picked, fills in the same way once the field is left.
    func controlTextDidEndEditing(_ obj: Notification) {
        if let match = hosts.first(where: { $0.alias == host.stringValue }) { fill(from: match) } else { showResolved() }
    }

    func controlTextDidChange(_ obj: Notification) {
        showResolved()
    }

    private func fill(from config: SSHHost) {
        host.stringValue = config.alias
        port.stringValue = config.port.map(String.init) ?? ""
        key.stringValue = config.identityFile ?? ""
        if let previous = lastPath(config.alias) { path.stringValue = previous }
        showResolved()
    }

    /// Under the server field: where a Host from the config connects, to check it's the right one.
    /// The line stays, blank, for other servers, so the form keeps the size the alert gave it.
    private func showResolved() {
        resolved.stringValue = hosts.first { $0.alias == host.stringValue }.map { "→ " + $0.summary } ?? " "
    }
}
