import Foundation

/// The structure of a whole database, every table and view, written out as a Markdown document:
/// columns, keys, indexes, foreign keys, triggers and the CREATE statements.
enum SchemaDocument {
    static func markdown(for database: DatabaseConnection, date: Date = Date()) throws -> String {
        let objects = try database.objects()
        let tables = objects.filter { $0.kind == .table }
        let views = objects.filter { $0.kind == .view }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var out: [String] = []
        out.append("# " + tr("資料庫結構：\(database.name)", "Database Structure: \(database.name)"))
        out.append("")
        out.append("- " + tr("位置", "Location") + tr("：", ": ") + "`\(database.location)`")
        out.append("- " + tr("產生時間", "Generated") + tr("：", ": ") + formatter.string(from: date))
        out.append("- " + tr("資料表 \(tables.count) 個，視圖 \(views.count) 個", "\(tables.count) table\(tables.count == 1 ? "" : "s"), \(views.count) view\(views.count == 1 ? "" : "s")"))

        if !objects.isEmpty {
            out.append("")
            out.append("## " + tr("目錄", "Contents"))
            out.append("")
            for object in tables { out.append("- " + tr("資料表", "Table") + " `\(object.name)`") }
            for object in views { out.append("- " + tr("視圖", "View") + " `\(object.name)`") }
        }

        if !tables.isEmpty {
            out.append("")
            out.append("## " + tr("資料表", "Tables"))
            for table in tables { out += try section(table, in: database) }
        }
        if !views.isEmpty {
            out.append("")
            out.append("## " + tr("視圖", "Views"))
            for view in views { out += try section(view, in: database) }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// One table or view on its own: what can be said of it, then its structure as in the whole
    /// database's document.
    static func markdown(for object: DatabaseObject, in database: DatabaseConnection, date: Date = Date()) throws -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var out = ["# " + (object.kind == .table ? tr("資料表：", "Table: ") : tr("視圖：", "View: ")) + object.name, ""]
        out.append("- " + tr("資料庫", "Database") + tr("：", ": ") + "`\(database.location)`")
        out.append("- " + tr("產生時間", "Generated") + tr("：", ": ") + formatter.string(from: date))
        if object.kind == .table, let facts = try database.facts(of: object.name) {
            out += ["", "**" + tr("資料表資訊", "Table Info") + "**", ""]
            out += table([tr("項目", "Item"), tr("值", "Value")], "ll", factRows(facts, rows: try database.rowCount(of: object.name)))
        }
        var body = try section(object, in: database)
        // Its own "### name" heading, which the title says, and a table's row count, which the facts do.
        body.removeFirst(object.kind == .table ? 5 : 3)
        return (out + ["", "**" + tr("欄位", "Columns") + "**", ""] + body).joined(separator: "\n") + "\n"
    }

    /// A table's facts as label and value, for the Structure tab and the table's document.
    static func factRows(_ facts: TableFacts, rows: Int) -> [[String]] {
        var out: [[String]] = []
        func add(_ zh: String, _ en: String, _ value: String?) {
            if let value, !value.isEmpty { out.append([tr(zh, en), value]) }
        }
        let number = NumberFormatter()
        number.numberStyle = .decimal
        func count(_ n: Int?) -> String? { n.map { number.string(from: NSNumber(value: $0)) ?? String($0) } }
        add("資料列", "Rows", count(rows))
        add("總大小", "Total Size", facts.totalLength.map { TableFacts.bytes($0) })
        add("資料大小", "Data Size", facts.dataLength.map { TableFacts.bytes($0) })
        add("索引大小", "Index Size", facts.dataLength == nil ? nil : TableFacts.bytes(facts.indexLength))
        add("未使用的空間", "Unused Space", facts.unused.map { TableFacts.bytes($0) })
        add("平均每列", "Average Row", facts.dataLength.flatMap { rows > 0 ? TableFacts.bytes($0 / rows) : nil })
        if facts.autoIncrement {
            add("下一個自動遞增值", "Next AUTOINCREMENT", count(facts.nextRowID))
        } else {
            add("下一個 rowid", "Next rowid", count(facts.nextRowID))
        }
        add("選項", "Options", facts.options.joined(separator: ", "))
        return out
    }

    private static func section(_ object: DatabaseObject, in database: DatabaseConnection) throws -> [String] {
        var out = ["", "### \(object.name)", ""]
        if object.kind == .table {
            out.append(tr("資料列：", "Rows: ") + String(try database.rowCount(of: object.name)))
            out.append("")
        }

        // A view over a table that's gone can't list its columns; say so and carry on.
        let columns: [Column]
        do {
            columns = try database.columns(of: object.name)
        } catch {
            out += ["> ⚠️ " + tr("無法讀取欄位：", "Couldn’t read the columns: ") + error.localizedDescription]
            if let sql = try database.createStatement(of: object.name) {
                out += ["", "**" + tr("建立語句", "CREATE Statement") + "**", "", "```sql", sql, "```"]
            }
            return out
        }
        let unique = object.kind == .table ? Set(try database.indexes(of: object.name)
            .filter { $0.unique && $0.columns.count == 1 }.compactMap(\.columns.first)) : []
        if object.kind == .table {
            out += table(["#", tr("欄位", "Column"), tr("類型", "Type"), tr("非空", "Not Null"),
                          tr("唯一", "Unique"), tr("預設值", "Default"), tr("主鍵", "Key")], "rllccLc",
                         columns.enumerated().map { i, column in [String(i + 1), "`\(column.name)`", column.type, column.notNull ? "✓" : "",
                                unique.contains(column.name) && column.primaryKey == 0 ? "✓" : "", column.defaultValue.map { "`\($0)`" } ?? "",
                                column.primaryKey > 0 ? String(column.primaryKey) : ""] })
        } else {
            out += table(["#", tr("欄位", "Column"), tr("類型", "Type")], "rll",
                         columns.enumerated().map { i, column in [String(i + 1), "`\(column.name)`", column.type] })
        }

        if object.kind == .table {
            let keys = try database.run("PRAGMA foreign_key_list(\(Database.quote(object.name)))").rows
            if !keys.isEmpty {
                out += ["", "**" + tr("外鍵", "Foreign Keys") + "**", ""]
                // One row per column; a key over several columns shares its id.
                out += table([tr("欄位", "Column"), tr("參照", "References"), "ON UPDATE", "ON DELETE"], "llll",
                             keys.filter { $0.count >= 7 }.map { key in
                                 ["`\(key[3].display)`", "`\(key[2].display)`(`\(key[4].display)`)", key[5].display, key[6].display] })
            }

            let indexes = try database.indexes(of: object.name)
            if !indexes.isEmpty {
                out += ["", "**" + tr("索引", "Indexes") + "**", ""]
                out += table([tr("名稱", "Name"), tr("唯一", "Unique"), tr("欄位", "Columns")], "lcl",
                             indexes.map { index in ["`\(index.name)`", index.unique ? "✓" : "",
                                                     index.columns.map { "`\($0)`" }.joined(separator: ", ")] })
            }
        }

        let triggers = try database.run("SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ? ORDER BY name",
                                        [.text(object.name)]).rows
        if !triggers.isEmpty {
            out += ["", "**" + tr("觸發程序", "Triggers") + "**"]
            for trigger in triggers {
                out += ["", "- `\(trigger[0].display)`", "", "```sql", trigger[1].display, "```"]
            }
        }

        if let sql = try database.createStatement(of: object.name) {
            out += ["", "**" + tr("建立語句", "CREATE Statement") + "**", "", "```sql", sql, "```"]
        }
        return out
    }

    /// A Markdown table padded so its columns line up in plain text too, counting CJK characters
    /// as two columns wide. `align` has a letter per column: l, c or r (L is left too).
    private static func table(_ header: [String], _ align: String, _ rows: [[String]]) -> [String] {
        let cells = ([header] + rows).map { $0.map {
            $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
        } }
        let alignments = Array(align)
        let widths = header.indices.map { i in max(3, cells.map { width($0[i]) }.max() ?? 0) }
        func line(_ row: [String]) -> String {
            "| " + row.enumerated().map { i, cell in
                let pad = String(repeating: " ", count: widths[i] - width(cell))
                switch alignments[i] {
                case "r": return pad + cell
                case "c": return String(pad.prefix(pad.count / 2)) + cell + String(pad.dropFirst(pad.count / 2))
                default: return cell + pad
                }
            }.joined(separator: " | ") + " |"
        }
        let rule = "|" + widths.enumerated().map { i, w in
            switch alignments[i] {
            case "r": return String(repeating: "-", count: w + 1) + ":"
            case "c": return ":" + String(repeating: "-", count: w) + ":"
            default: return String(repeating: "-", count: w + 2)
            }
        }.joined(separator: "|") + "|"
        return [line(cells[0]), rule] + cells.dropFirst().map(line)
    }

    /// How many columns the text takes in a monospaced font: East Asian characters take two.
    private static func width(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { sum, scalar in
            let v = scalar.value
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || (0x20000...0x3FFFD).contains(v)
            return sum + (wide ? 2 : 1)
        }
    }
}
