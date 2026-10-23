import Foundation

/// What to import from a CSV file into a table, and the SQL that does it.
struct CSVImport {
    let table: String
    let columns: [Column]
    /// For each of the table's columns, the CSV field that fills it, or nil to leave it to its default.
    var sources: [Int?]
    /// The rows to import (without the header line, if the file has one).
    var rows: [[String]]
    var emptyIsNull = true
    /// Delete the table's rows first, rather than adding to them.
    var replace = false

    /// Rows per INSERT: SQLite allows 500 rows in one VALUES list.
    private static let chunk = 500

    var hasColumns: Bool { sources.contains { $0 != nil } }

    /// One transaction: everything is imported, or (on an error) nothing. Over SSH it all goes to
    /// sqlite3 at once, which stops at the first error, so the transaction is never committed.
    var script: String {
        let used = columns.indices.filter { sources[$0] != nil }
        let names = used.map { Database.quote(columns[$0].name) }.joined(separator: ", ")
        var sql = "BEGIN;\n"
        if replace { sql += "DELETE FROM \(Database.quote(table));\n" }
        var start = 0
        while start < rows.count {
            let values = rows[start..<min(start + Self.chunk, rows.count)].map { row in
                "(" + used.map { literal(field(sources[$0]!, of: row), for: columns[$0]) }.joined(separator: ", ") + ")"
            }
            sql += "INSERT INTO \(Database.quote(table)) (\(names)) VALUES\n" + values.joined(separator: ",\n") + ";\n"
            start += Self.chunk
        }
        return sql + "COMMIT;\n"
    }

    private func field(_ index: Int, of row: [String]) -> String {
        row.indices.contains(index) ? row[index] : ""
    }

    /// A field as SQL. Text goes as text: a typed column converts it by its type, as when typed
    /// in. A column with no declared type converts nothing, so numbers go to it as numbers.
    private func literal(_ text: String, for column: Column) -> String {
        if text.isEmpty, emptyIsNull { return "NULL" }
        if column.type.isEmpty {
            if let n = Int64(text) { return String(n) }
            if let d = Double(text), d.isFinite, text.first?.isNumber == true || text.first == "-" { return Value.real(d).sqlLiteral }
        }
        return Value.text(text).sqlLiteral
    }

    /// Matches the table's columns to the CSV's by name, ignoring case and spaces at the ends;
    /// with no header, by position.
    static func match(_ columns: [Column], header: [String]?, fieldCount: Int) -> [Int?] {
        guard let header else { return columns.indices.map { $0 < fieldCount ? $0 : nil } }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return columns.map { column in names.firstIndex(of: column.name.lowercased()) }
    }
}
