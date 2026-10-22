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

/// A table as it was when editing began: what changing it needs to know, read once so that
/// remaking the SQL as the user types doesn't ask the database (a server, perhaps) each time.
struct TableSnapshot {
    let name: String
    let columns: [ColumnDraft]
    let createStatement: String
    /// Indexes made with CREATE INDEX (not the ones constraints make), with their SQL.
    let indexes: [(index: Index, sql: String)]
    let triggers: [String]
    let foreignKeys: Bool
}

/// Makes the SQL that creates a table, or changes one to match its edited columns. SQLite can
/// only rename tables and add columns in place everywhere (renaming and dropping columns came in
/// 3.25 and 3.35, and servers may have older), so other changes rebuild the table: a new one is
/// made, the rows copied over, the old one dropped and the new one renamed, inside a transaction.
enum TableDesign {
    static let types = ["INTEGER", "TEXT", "REAL", "NUMERIC", "BLOB"]

    static func snapshot(of table: String, in database: DatabaseConnection) throws -> TableSnapshot {
        try TableSnapshot(
            name: table,
            columns: drafts(of: table, in: database),
            createStatement: database.createStatement(of: table) ?? "",
            indexes: database.indexes(of: table).filter { !$0.name.hasPrefix("sqlite_autoindex") }
                .map { ($0, try database.createStatement(of: $0.name) ?? "") },
            triggers: database.run("SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?", [.text(table)])
                .rows.map { $0[0].display },
            foreignKeys: database.run("PRAGMA foreign_keys").rows.first?.first == .integer(1))
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
    static func problem(name: String, columns: [ColumnDraft]) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return tr("請輸入資料表名稱。", "Enter a name for the table.") }
        if columns.isEmpty { return tr("資料表至少要有一個欄位。", "A table needs at least one column.") }
        let names = columns.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if names.contains("") { return tr("每個欄位都要有名稱。", "Every column needs a name.") }
        if Set(names).count != names.count { return tr("欄位名稱不能重複。", "Column names must be different.") }
        return nil
    }

    // MARK: Creating

    static func createSQL(name: String, columns: [ColumnDraft]) -> String {
        let keys = columns.filter(\.primaryKey)
        var lines = columns.map { definition($0, inlineKey: keys.count == 1) }
        if keys.count > 1 { lines.append("PRIMARY KEY (" + keys.map { Database.quote($0.name) }.joined(separator: ", ") + ")") }
        return "CREATE TABLE \(Database.quote(name)) (\n    " + lines.joined(separator: ",\n    ") + "\n);"
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
    static func alterSQL(_ table: TableSnapshot, newName: String, columns: [ColumnDraft]) -> (sql: String, warnings: [String]) {
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
            return (statements.joined(separator: "\n"), [])
        }
        return rebuildSQL(table, newName: newName, columns: columns)
    }

    /// ADD COLUMN can't add a key or a unique column, nor a NOT NULL one without a default.
    private static func canAdd(_ column: ColumnDraft) -> Bool {
        !column.primaryKey && !column.unique && (!column.notNull || !column.defaultValue.isEmpty)
    }

    private static func rebuildSQL(_ table: TableSnapshot, newName: String, columns: [ColumnDraft]) -> (sql: String, warnings: [String]) {
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

        // Indexes the table had, made again on the new one with renamed columns, where they still apply.
        var indexes: [String] = []
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
