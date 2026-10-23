import AppKit

/// Conditions over the Data tab that narrow the rows shown. Each picks a column, a comparison and
/// a value, and joins the one before it with AND or OR; as in SQL, AND binds tighter than OR.
/// A condition still missing its value is left out until it has one.
final class FilterBar: NSStackView {
    enum Operator: String, CaseIterable {
        case equal = "=", notEqual = "!=", greater = ">", less = "<", greaterOrEqual = ">=", lessOrEqual = "<="
        case like = "LIKE", notLike = "NOT LIKE"
        case isNull = "IS NULL", isNotNull = "IS NOT NULL", isEmpty = "IS EMPTY", isNotEmpty = "IS NOT EMPTY"

        var takesValue: Bool {
            switch self {
            case .isNull, .isNotNull, .isEmpty, .isNotEmpty: return false
            default: return true
            }
        }
    }

    /// Called when the conditions change what they select, to load the rows again.
    var onChange: (() -> Void)?

    private struct Condition {
        let stack: NSStackView
        let label: NSTextField        // "Filter", in front of the first condition
        let connector: NSPopUpButton  // AND or OR, in front of the others
        let column: NSPopUpButton
        let comparison: NSPopUpButton
        let value: NSTextField
        let remove: NSButton
        let add: NSButton
    }

    private var columns: [Column] = []
    private var conditions: [Condition] = []
    private var applied: (sql: String, bindings: [Value])?

    var isShowing: Bool { !conditions.isEmpty }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 6, right: 8)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The WHERE clause the conditions make, without the WHERE, and the values for its `?`s.
    var condition: (sql: String, bindings: [Value])? {
        var sql = "", bindings: [Value] = []
        for condition in conditions {
            guard let name = condition.column.titleOfSelectedItem,
                  let column = columns.first(where: { $0.name == name }),
                  let comparison = Operator(rawValue: condition.comparison.titleOfSelectedItem ?? "") else { continue }
            let text = condition.value.stringValue
            if comparison.takesValue, text.isEmpty { continue }
            let quoted = Database.quote(name)
            let term: String
            switch comparison {
            case .isNull, .isNotNull: term = "\(quoted) \(comparison.rawValue)"
            case .isEmpty: term = "\(quoted) = ''"
            case .isNotEmpty: term = "\(quoted) <> ''"
            case .like, .notLike:
                term = "\(quoted) \(comparison.rawValue) ?"
                bindings.append(.text(text))
            default:
                term = "\(quoted) \(comparison.rawValue) ?"
                bindings.append(Self.value(text, for: column))
            }
            if !sql.isEmpty { sql += " \(condition.connector.titleOfSelectedItem ?? "AND") " }
            sql += term
        }
        return sql.isEmpty ? nil : (sql, bindings)
    }

    /// Text compares with a typed column by the column's type, so it goes as typed. A column
    /// with no declared type (a view's expression, say) converts nothing, so a number there has
    /// to be given as a number to match one.
    private static func value(_ text: String, for column: Column) -> Value {
        guard column.type.isEmpty else { return .text(text) }
        if let n = Int64(text) { return .integer(n) }
        if let d = Double(text) { return .real(d) }
        return .text(text)
    }

    /// A condition as it stands, to put back later (when its connection's tab is shown again).
    struct Saved {
        let connector: String
        let column: String
        let comparison: String
        let value: String
    }

    var saved: [Saved] {
        conditions.map { Saved(connector: $0.connector.titleOfSelectedItem ?? "AND", column: $0.column.titleOfSelectedItem ?? "",
                               comparison: $0.comparison.titleOfSelectedItem ?? "=", value: $0.value.stringValue) }
    }

    /// Puts saved conditions back, after `reset(columns:)` gave the table's columns. Says nothing
    /// to the owner, which loads the rows itself.
    func restore(_ saved: [Saved]) {
        for entry in saved {
            addCondition(after: conditions.last)
            let condition = conditions[conditions.count - 1]
            condition.connector.selectItem(withTitle: entry.connector)
            if condition.column.indexOfItem(withTitle: entry.column) >= 0 { condition.column.selectItem(withTitle: entry.column) }
            condition.comparison.selectItem(withTitle: entry.comparison)
            condition.value.stringValue = entry.value
            updateValueField(condition)
        }
        isHidden = conditions.isEmpty
        applied = condition
    }

    /// For a newly chosen table: its columns, and no conditions.
    func reset(columns: [Column]) {
        self.columns = columns
        for condition in conditions { condition.stack.removeFromSuperview() }
        conditions = []
        applied = nil
        isHidden = true
    }

    /// For the same table after a refresh, whose columns may have changed: keeps the conditions
    /// whose column is still there.
    func update(columns: [Column]) {
        self.columns = columns
        for condition in conditions {
            let name = condition.column.titleOfSelectedItem
            if let name, columns.contains(where: { $0.name == name }) {
                fillColumns(condition.column, selecting: name)
            } else {
                remove(condition)
            }
        }
        isHidden = conditions.isEmpty
        changed()
    }

    /// Shows the bar with a condition to fill in, or puts the bar away with all its conditions.
    func toggle() {
        if isShowing {
            for condition in conditions { condition.stack.removeFromSuperview() }
            conditions = []
            isHidden = true
            changed()
        } else {
            guard !columns.isEmpty else { return NSSound.beep() }
            addCondition(after: nil)
            isHidden = false
            window?.makeFirstResponder(conditions.first?.value)
        }
    }

    func applyLanguage() {
        for condition in conditions {
            relabel(condition)
        }
    }

    // MARK: Conditions

    private func addCondition(after previous: Condition?) {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        let connector = popUp(["AND", "OR"])
        let column = popUp([])
        fillColumns(column, selecting: previous?.column.titleOfSelectedItem)
        let comparison = popUp(Operator.allCases.map(\.rawValue))
        let value = NSTextField()
        value.controlSize = .small
        value.font = .systemFont(ofSize: 11)
        value.target = self
        value.action = #selector(valueChanged(_:))
        value.cell?.sendsActionOnEndEditing = true
        value.setContentHuggingPriority(.init(1), for: .horizontal)
        value.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        let remove = button("minus.circle", #selector(removeCondition(_:)))
        let add = button("plus.circle", #selector(addCondition(_:)))
        // The label and the AND/OR menu share a place, so the columns line up row to row.
        let lead = NSView()
        for view in [label, connector] {
            view.translatesAutoresizingMaskIntoConstraints = false
            lead.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: lead.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: lead.trailingAnchor),
                view.centerYAnchor.constraint(equalTo: lead.centerYAnchor),
            ])
        }
        lead.widthAnchor.constraint(equalToConstant: 64).isActive = true
        lead.heightAnchor.constraint(equalTo: connector.heightAnchor).isActive = true
        let stack = NSStackView(views: [lead, column, comparison, value, remove, add])
        stack.spacing = 4
        let condition = Condition(stack: stack, label: label, connector: connector, column: column,
                                  comparison: comparison, value: value, remove: remove, add: add)
        let index = previous.flatMap { p in conditions.firstIndex { $0.stack === p.stack } }.map { $0 + 1 } ?? conditions.count
        conditions.insert(condition, at: index)
        insertArrangedSubview(stack, at: index)
        stack.widthAnchor.constraint(equalTo: widthAnchor, constant: -16).isActive = true
        updateLeads()
        relabel(condition)
    }

    private func relabel(_ condition: Condition) {
        condition.label.stringValue = tr("篩選", "Filter")
        condition.remove.toolTip = tr("移除這個條件", "Remove This Condition")
        condition.add.toolTip = tr("再加一個條件", "Add a Condition")
        updateValueField(condition)
    }

    private func remove(_ condition: Condition) {
        condition.stack.removeFromSuperview()
        conditions.removeAll { $0.stack === condition.stack }
        updateLeads()
    }

    /// Only the first condition says "Filter"; the rest say how they join the one before.
    private func updateLeads() {
        for (i, condition) in conditions.enumerated() {
            condition.label.isHidden = i > 0
            condition.connector.isHidden = i == 0
        }
    }

    private func updateValueField(_ condition: Condition) {
        let comparison = Operator(rawValue: condition.comparison.titleOfSelectedItem ?? "") ?? .equal
        condition.value.isEnabled = comparison.takesValue
        condition.value.placeholderString = !comparison.takesValue ? ""
            : comparison == .like || comparison == .notLike ? tr("例如 %文字%（% 代表任意字）", "e.g. %text% (% matches anything)")
            : tr("值", "Value")
    }

    private func fillColumns(_ popUp: NSPopUpButton, selecting name: String?) {
        popUp.removeAllItems()
        popUp.addItems(withTitles: columns.map(\.name))
        if let name, popUp.indexOfItem(withTitle: name) >= 0 { popUp.selectItem(withTitle: name) }
    }

    private func condition(of view: NSView) -> Condition? {
        conditions.first { view.isDescendant(of: $0.stack) }
    }

    // MARK: Actions

    @objc private func popUpChanged(_ sender: NSPopUpButton) {
        if let condition = condition(of: sender) { updateValueField(condition) }
        changed()
    }

    @objc private func valueChanged(_ sender: NSTextField) { changed() }

    @objc private func addCondition(_ sender: NSButton) {
        guard let condition = condition(of: sender) else { return }
        addCondition(after: condition)
        // The new one has no value yet, so nothing changes until it's filled in.
    }

    @objc private func removeCondition(_ sender: NSButton) {
        guard let condition = condition(of: sender) else { return }
        remove(condition)
        isHidden = conditions.isEmpty
        changed()
    }

    /// Tells the owner only when the rows selected would differ, so tabbing between fields
    /// doesn't reload.
    private func changed() {
        let now = condition
        guard now?.sql != applied?.sql || now?.bindings != applied?.bindings else { return }
        applied = now
        onChange?()
    }

    // MARK: Controls

    private func popUp(_ titles: [String]) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.controlSize = .small
        popUp.font = .systemFont(ofSize: 11)
        popUp.addItems(withTitles: titles)
        popUp.target = self
        popUp.action = #selector(popUpChanged(_:))
        return popUp
    }

    private func button(_ symbol: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))!
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        return button
    }
}
