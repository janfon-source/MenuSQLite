import Foundation

/// A column as the table editor shows it. `original` is the column it was in the table before
/// editing, so its data can follow it through a rename; nil for a column being added.
struct ColumnDraft: Equatable {
    var name = ""
    var type = "TEXT"
    var primaryKey = false
    var notNull = false
    var unique = false
    /// As SQL: 0, 'text', CURRENT_TIMESTAMP. Plain words are quoted as text when the SQL is made.
    var defaultValue = ""
    var autoincrement = false
    var original: String?
}

/// An index made with CREATE INDEX, as the table editor shows it: its name, whether it's unique,
/// and its columns, each written as in SQL, maybe with an order or a collation: `name`,
/// `created DESC`, `title COLLATE NOCASE`. `original` is its name before editing; nil for a new one.
struct IndexDraft: Equatable {
    enum Kind: String, CaseIterable { case index = "INDEX", unique = "UNIQUE" }
    var name = ""
    var kind = Kind.index
    var columns: [String] = []
    var original: String?

    /// The column a part names: what comes before an order or a collation, without quotes.
    static func column(of part: String) -> String {
        let name = part.trimmingCharacters(in: .whitespaces).prefix { $0 != "(" && $0 != " " }
        if name.count >= 2, let first = name.first, first == name.last, first == "\"" || first == "`" {
            return String(name.dropFirst().dropLast())
        }
        return String(name)
    }

    /// The part with its column called something else, the rest kept.
    static func renaming(_ part: String, to name: String) -> String {
        let text = part.trimmingCharacters(in: .whitespaces)
        return name + text.dropFirst(text.prefix { $0 != "(" && $0 != " " }.count)
    }

    /// The columns as text, for the editor's field: name, created DESC
    var columnsText: String { columns.joined(separator: ", ") }

    /// The columns from the editor's field, split at commas outside parentheses.
    static func columns(from text: String) -> [String] {
        var parts: [String] = [], current = "", depth = 0
        for character in text {
            if character == "(" { depth += 1 } else if character == ")" { depth -= 1 }
            if character == ",", depth == 0 { parts.append(current); current = "" } else { current.append(character) }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// CREATE [UNIQUE] INDEX "name" ON "table" ("a", "b" DESC);
    func createSQL(on table: String) -> String {
        let parts = columns.map { part -> String in
            let text = part.trimmingCharacters(in: .whitespaces)
            return Database.quote(Self.column(of: text)) + text.dropFirst(text.prefix { $0 != "(" && $0 != " " }.count)
        }
        return "CREATE \(kind == .unique ? "UNIQUE " : "")INDEX \(Database.quote(name)) ON \(Database.quote(table)) ("
            + parts.joined(separator: ", ") + ");"
    }
}

/// A table as it was when editing began: what changing it needs to know, read once so that
/// remaking the SQL as the user types doesn't ask the database (a server, perhaps) each time.
struct TableSnapshot {
    let name: String
    let columns: [ColumnDraft]
    let createStatement: String
    /// Indexes made with CREATE INDEX that the editor can't show (partial ones, with WHERE, and
    /// those on expressions), with their SQL, to make again as they were on a rebuild.
    let indexes: [(index: Index, sql: String)]
    let triggers: [String]
    let foreignKeys: Bool
    /// The other CREATE INDEX indexes, which the editor lists and changes.
    var indexDrafts: [IndexDraft] = []
}

/// Makes the SQL that creates a table, or changes one to match its edited columns. SQLite can
/// only rename tables and add columns in place everywhere (renaming and dropping columns came in
/// 3.25 and 3.35, and servers may have older), so other changes rebuild the table: a new one is
/// made, the rows copied over, the old one dropped and the new one renamed, inside a transaction.
enum TableDesign {
    /// The types the editor offers: SQLite's own five. Other names (VARCHAR, DECIMAL…) can still
    /// be typed, with a length in the field beside.
    static let types = ["INTEGER", "TEXT", "REAL", "NUMERIC", "BLOB"]

    /// What a type's length starts as when it's chosen or typed.
    static let defaultLengths = ["VARCHAR": "255", "CHAR": "10", "DECIMAL": "10,2"]

    /// Types that take no length at all.
    static let lengthless: Set<String> = ["INTEGER", "INT", "TEXT", "REAL", "BLOB", "BOOLEAN", "DATE", "DATETIME", "ANY"]

    /// Types whose "length" isn't a size: DECIMAL's digits and decimals.
    private static let otherLengths: Set<String> = ["DECIMAL", "NUMERIC"]

    /// A type split for the editor: its name with any words after the parentheses, and what's in
    /// them. `VARCHAR(40)` is ("VARCHAR", "40").
    static func split(_ type: String) -> (base: String, length: String) {
        let text = type.trimmingCharacters(in: .whitespaces)
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return (text, "") }
        let base = text[..<open].trimmingCharacters(in: .whitespaces)
        let rest = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return (rest.isEmpty ? base : base + " " + rest, String(text[text.index(after: open)..<close]))
    }

    /// The type as SQL from the editor's two fields: the length goes after the type's first word.
    static func join(_ base: String, _ length: String) -> String {
        let base = base.trimmingCharacters(in: .whitespaces), length = length.trimmingCharacters(in: .whitespaces)
        let words = base.split(separator: " ", maxSplits: 1)
        guard let first = words.first, !length.isEmpty else { return base }
        return first + "(" + length + ")" + (words.count > 1 ? " " + words[1] : "")
    }

    /// The length a column gets when its type is changed from `old` to `new`: none for a type
    /// that takes none, the usual one when there was none or its meaning changes, and otherwise
    /// the one it had.
    static func length(changingType old: String, to new: String, from length: String) -> String {
        func key(_ base: String) -> String { base.split(separator: " ").first.map { $0.uppercased() } ?? "" }
        let from = key(old), to = key(new)
        if lengthless.contains(to) { return "" }
        if length.isEmpty || otherLengths.contains(from) != otherLengths.contains(to) { return defaultLengths[to] ?? "" }
        return length
    }

    /// What the length field suggests for a type, when it's empty.
    static func lengthHint(for base: String) -> String {
        let key = base.split(separator: " ").first.map { $0.uppercased() } ?? ""
        if lengthless.contains(key) { return "" }
        return otherLengths.contains(key) ? "10,2" : defaultLengths[key] ?? tr("長度", "length")
    }

    static func snapshot(of table: String, in database: DatabaseConnection) throws -> TableSnapshot {
        var editable: [IndexDraft] = [], fixed: [(index: Index, sql: String)] = []
        for index in try database.indexes(of: table) where !index.name.hasPrefix("sqlite_autoindex") {
            let sql = try database.createStatement(of: index.name) ?? ""
            let partial = sql.range(of: #"\bWHERE\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            if !partial, let parts = indexParts(of: index.name, in: database), !parts.isEmpty {
                editable.append(IndexDraft(name: index.name, kind: index.unique ? .unique : .index, columns: parts, original: index.name))
            } else {
                fixed.append((index, sql))
            }
        }
        return try TableSnapshot(
            name: table,
            columns: drafts(of: table, in: database),
            createStatement: database.createStatement(of: table) ?? "",
            indexes: fixed.sorted { $0.index.name < $1.index.name },
            triggers: database.run("SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?", [.text(table)])
                .rows.map { $0[0].display },
            foreignKeys: database.run("PRAGMA foreign_keys").rows.first?.first == .integer(1),
            indexDrafts: editable.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    /// An index's columns with their order and collation, from index_xinfo; from index_info
    /// (names alone) on sqlite3 older than 3.9, which hasn't the other. Nil for an index on an
    /// expression, which has no column name to show.
    private static func indexParts(of index: String, in database: DatabaseConnection) -> [String]? {
        if let rows = try? database.run("PRAGMA index_xinfo(\(Database.quote(index)))").rows, !rows.isEmpty, rows[0].count >= 6 {
            var parts: [String] = []
            for row in rows where row[5] == .integer(1) {   // the key's columns, not the rowid after them
                guard row[2] != .null else { return nil }
                var part = row[2].display
                if row[4] != .null, row[4].display.uppercased() != "BINARY" { part += " COLLATE \(row[4].display)" }
                if row[3] == .integer(1) { part += " DESC" }
                parts.append(part)
            }
            return parts
        }
        guard let rows = try? database.run("PRAGMA index_info(\(Database.quote(index)))").rows,
              !rows.contains(where: { $0.count < 3 || $0[2] == .null }) else { return nil }
        return rows.map { $0[2].display }
    }

    /// The columns of an existing table, as drafts for editing.
    static func drafts(of table: String, in database: DatabaseConnection) throws -> [ColumnDraft] {
        let sql = try database.createStatement(of: table) ?? ""
        let uniqueColumns = Set(try database.indexes(of: table).filter { $0.unique && $0.columns.count == 1 && $0.name.hasPrefix("sqlite_autoindex") }
            .compactMap(\.columns.first))
        let autoincrement = sql.range(of: "AUTOINCREMENT", options: .caseInsensitive) != nil
        return try database.columns(of: table).map { column in
            ColumnDraft(name: column.name, type: column.type, primaryKey: column.primaryKey > 0, notNull: column.notNull,
                        unique: uniqueColumns.contains(column.name), defaultValue: column.defaultValue ?? "",
                        autoincrement: autoincrement && column.primaryKey > 0, original: column.name)
        }
    }

    /// What's wrong with the draft, for the editor to show; nil when it can be saved.
    static func problem(name: String, columns: [ColumnDraft], indexes: [IndexDraft] = []) -> String? {
        if let problem = columnProblem(name: name, columns: columns) { return problem }
        let names = Set(columns.map { $0.name.lowercased() })
        let named = indexes.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if named.contains("") { return tr("每個索引都要有名稱。", "Every index needs a name.") }
        if Set(named).count != named.count { return tr("索引名稱不能重複。", "Index names must be different.") }
        for index in indexes {
            if index.columns.isEmpty { return tr("索引「\(index.name)」至少要有一個欄位。", "The index “\(index.name)” needs at least one column.") }
            if let missing = index.columns.map(IndexDraft.column(of:)).first(where: { !names.contains($0.lowercased()) }) {
                return tr("索引「\(index.name)」用到的欄位「\(missing)」不在資料表裡。", "The index “\(index.name)” uses “\(missing)”, which isn’t a column of the table.")
            }
        }
        return nil
    }

    private static func columnProblem(name: String, columns: [ColumnDraft]) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return tr("請輸入資料表名稱。", "Enter a name for the table.") }
        if columns.isEmpty { return tr("資料表至少要有一個欄位。", "A table needs at least one column.") }
        let names = columns.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if names.contains("") { return tr("每個欄位都要有名稱。", "Every column needs a name.") }
        if Set(names).count != names.count { return tr("欄位名稱不能重複。", "Column names must be different.") }
        return nil
    }

    // MARK: Creating

    static func createSQL(name: String, columns: [ColumnDraft], indexes: [IndexDraft] = []) -> String {
        let keys = columns.filter(\.primaryKey)
        var lines = columns.map { definition($0, inlineKey: keys.count == 1) }
        if keys.count > 1 { lines.append("PRIMARY KEY (" + keys.map { Database.quote($0.name) }.joined(separator: ", ") + ")") }
        return (["CREATE TABLE \(Database.quote(name)) (\n    " + lines.joined(separator: ",\n    ") + "\n);"]
                + indexes.map { $0.createSQL(on: name) }).joined(separator: "\n")
    }

    /// One column's definition. A key of several columns goes at the end of the table instead.
    private static func definition(_ column: ColumnDraft, inlineKey: Bool) -> String {
        var parts = [Database.quote(column.name)]
        let type = column.type.trimmingCharacters(in: .whitespaces)
        if !type.isEmpty { parts.append(type) }
        if column.primaryKey && inlineKey {
            parts.append("PRIMARY KEY")
            // AUTOINCREMENT is allowed only on an INTEGER PRIMARY KEY.
            if column.autoincrement && type.uppercased() == "INTEGER" { parts.append("AUTOINCREMENT") }
        }
        if column.notNull { parts.append("NOT NULL") }
        if column.unique && !(column.primaryKey && inlineKey) { parts.append("UNIQUE") }
        let value = column.defaultValue.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty { parts.append("DEFAULT " + defaultSQL(value)) }
        return parts.joined(separator: " ")
    }

    /// A default as typed: numbers, NULL, the CURRENT_ times, quoted text and (expressions) stay
    /// as they are; anything else is taken as text and quoted.
    static func defaultSQL(_ value: String) -> String {
        let upper = value.uppercased()
        if Double(value) != nil || ["NULL", "TRUE", "FALSE", "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME"].contains(upper)
            || value.hasPrefix("'") || value.hasPrefix("(") || value.hasPrefix("X'") || value.hasPrefix("x'") {
            return value
        }
        return Value.text(value).sqlLiteral
    }

    // MARK: Changing

    /// The SQL that turns the table as it is into the edited one, and what the change gives up
    /// (an index whose column was dropped, say), to show before it runs.
    static func alterSQL(_ table: TableSnapshot, newName: String, columns: [ColumnDraft], indexes: [IndexDraft]? = nil) -> (sql: String, warnings: [String]) {
        let indexes = indexes ?? table.indexDrafts
        let before = table.columns
        let renamed = newName != table.name
        let target = Database.quote(newName)

        // Only renamed, or columns only added at the end in a way ADD COLUMN allows: no rebuild.
        let kept = Array(columns.prefix(before.count))
        let added = Array(columns.dropFirst(before.count))
        if kept == before, added.allSatisfy({ $0.original == nil && canAdd($0) }) {
            var statements: [String] = []
            if renamed { statements.append("ALTER TABLE \(Database.quote(table.name)) RENAME TO \(target);") }
            for column in added {
                statements.append("ALTER TABLE \(target) ADD COLUMN \(definition(column, inlineKey: false));")
            }
            // Indexes taken out or changed are dropped; changed and new ones made.
            var creates: [String] = []
            for old in table.indexDrafts {
                let edited = indexes.first { $0.original == old.name }
                guard edited != old else { continue }
                statements.append("DROP INDEX \(Database.quote(old.name));")
                if let edited { creates.append(edited.createSQL(on: newName)) }
            }
            statements += creates + indexes.filter { $0.original == nil }.map { $0.createSQL(on: newName) }
            return (statements.joined(separator: "\n"), [])
        }
        return rebuildSQL(table, newName: newName, columns: columns, editedIndexes: indexes)
    }

    /// ADD COLUMN can't add a key or a unique column, nor a NOT NULL one without a default.
    private static func canAdd(_ column: ColumnDraft) -> Bool {
        !column.primaryKey && !column.unique && (!column.notNull || !column.defaultValue.isEmpty)
    }

    private static func rebuildSQL(_ table: TableSnapshot, newName: String, columns: [ColumnDraft],
                                   editedIndexes: [IndexDraft]) -> (sql: String, warnings: [String]) {
        var warnings: [String] = []
        let before = table.columns
        if table.createStatement.range(of: #"\b(REFERENCES|FOREIGN\s+KEY|CHECK)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            warnings.append(tr("這個資料表有外鍵或 CHECK 限制，重建後不會保留，請在 SQL 分頁另外加回。",
                               "This table has foreign keys or CHECK constraints, which the rebuild doesn’t keep; add them back on the SQL tab."))
        }
        let temporary = "_menusqlite_new_" + newName
        // The rows move over column by column: renamed columns take their old data along.
        let carried = columns.filter { column in column.original.map { name in before.contains { $0.name == name } } ?? false }
        let dropped = before.filter { old in !columns.contains { $0.original == old.name } }
        if !dropped.isEmpty {
            warnings.append(tr("會刪除欄位 \(dropped.map(\.name).joined(separator: "、")) 和其中的資料。",
                               "Deletes the column\(dropped.count == 1 ? "" : "s") \(dropped.map(\.name).joined(separator: ", ")) and the data in \(dropped.count == 1 ? "it" : "them")."))
        }

        // The indexes as edited go on the new table (the old ones go with the old table); the
        // partial and expression ones it had are made again with renamed columns, where they apply.
        var indexes = editedIndexes.map { $0.createSQL(on: newName) }
        let renames = Dictionary(columns.compactMap { c in c.original.map { ($0, c.name) } }, uniquingKeysWith: { a, _ in a })
        for (index, sql) in table.indexes {
            let columnsNow = index.columns.compactMap { renames[$0] }
            let simple = sql.range(of: #"\bWHERE\b"#, options: [.regularExpression, .caseInsensitive]) == nil && !index.columns.isEmpty
            if columnsNow.count == index.columns.count, simple {
                indexes.append("CREATE \(index.unique ? "UNIQUE " : "")INDEX \(Database.quote(index.name)) ON \(Database.quote(newName)) ("
                               + columnsNow.map(Database.quote).joined(separator: ", ") + ");")
            } else {
                warnings.append(tr("索引 \(index.name) 用到的欄位改變了，不會保留。", "The index \(index.name) uses columns that change, so it isn’t kept."))
            }
        }
        if !table.triggers.isEmpty {
            warnings.append(tr("觸發程序 \(table.triggers.joined(separator: "、")) 會被刪除。",
                               "The trigger\(table.triggers.count == 1 ? "" : "s") \(table.triggers.joined(separator: ", ")) will be deleted."))
        }

        // Foreign keys are switched off for the rebuild and back to how they were after.
        let foreignKeys = table.foreignKeys ? "ON" : "OFF"
        let copy = carried.isEmpty ? "" : "INSERT INTO \(Database.quote(temporary)) (" + carried.map { Database.quote($0.name) }.joined(separator: ", ")
            + ")\n  SELECT " + carried.map { Database.quote($0.original!) }.joined(separator: ", ") + " FROM \(Database.quote(table.name));\n"
        let sql = """
            PRAGMA foreign_keys = OFF;
            PRAGMA legacy_alter_table = ON;
            BEGIN;
            \(createSQL(name: temporary, columns: columns))
            \(copy)DROP TABLE \(Database.quote(table.name));
            ALTER TABLE \(Database.quote(temporary)) RENAME TO \(Database.quote(newName));
            \(indexes.joined(separator: "\n"))
            COMMIT;
            PRAGMA legacy_alter_table = OFF;
            PRAGMA foreign_keys = \(foreignKeys);
            """
        return (sql.replacingOccurrences(of: "\n\n", with: "\n"), warnings)
    }

    /// Runs a change, rolling back what a failed statement left half done.
    static func apply(_ sql: String, to database: DatabaseConnection) throws {
        do {
            try database.run(sql)
        } catch {
            _ = try? database.run("ROLLBACK")
            _ = try? database.run("PRAGMA legacy_alter_table = OFF")
            throw error
        }
    }
}
