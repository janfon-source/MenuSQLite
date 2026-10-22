import Foundation
import SQLite3

/// One value from a SQLite cell, in the storage class SQLite gave it.
enum Value: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    /// How a grid cell shows it.
    var display: String {
        switch self {
        case .null: return "NULL"
        case .integer(let n): return String(n)
        case .real(let d): return String(d)
        case .text(let s): return s
        case .blob(let data): return tr("<BLOB \(data.count) 位元組>", "<BLOB \(data.count) bytes>")
        }
    }

    /// The value written as an SQL literal, for running SQL where values can't be bound.
    var sqlLiteral: String {
        switch self {
        case .null: return "NULL"
        case .integer(let n): return String(n)
        case .real(let d): return d.isFinite ? String(d) : (d > 0 ? "9e999" : "-9e999")
        case .text(let s): return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
        case .blob(let data): return "X'" + data.map { String(format: "%02X", $0) }.joined() + "'"
        }
    }

    /// How CSV export writes it: NULL as an empty field, BLOBs as hex.
    var csv: String {
        switch self {
        case .null: return ""
        case .blob(let data): return data.map { String(format: "%02x", $0) }.joined()
        default: return display
        }
    }
}

/// What a statement returned: its columns and rows, and how many rows it changed.
struct ResultSet {
    var columns: [String] = []
    var rows: [[Value]] = []
    var changes = 0
}

/// A table or view in the database.
struct DatabaseObject: Equatable {
    enum Kind: String { case table, view }
    let name: String
    let kind: Kind
}

/// A column, from PRAGMA table_info.
struct Column {
    let name: String
    let type: String
    let notNull: Bool
    let defaultValue: String?
    let primaryKey: Int   // its place in the primary key, from 1; 0 if not part of it
}

/// An index, from PRAGMA index_list and index_info.
struct Index {
    let name: String
    let unique: Bool
    let columns: [String]
}

struct DatabaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// An open database, on this Mac or on a server reached over SSH. Each kind only runs SQL;
/// reading the schema and changing rows are built on that, the same for both.
protocol DatabaseConnection: AnyObject {
    /// The file's name, for the window title.
    var name: String { get }
    /// Where it is, in full: a path, or the server and path.
    var location: String { get }
    /// How the recent list remembers it, and opens it again.
    var recentKey: String { get }
    var readOnly: Bool { get }

    /// Runs every statement in `sql` in turn. Returns the rows of the last statement that
    /// returns any (a query after an update, say), and the rows all of them changed.
    /// `bindings` fill the `?` placeholders, for a single statement.
    @discardableResult
    func run(_ sql: String, _ bindings: [Value]) throws -> ResultSet

    /// Adds a row of default values; returns its rowid.
    func insertRow(into table: String) throws -> Int64
}

extension DatabaseConnection {
    @discardableResult
    func run(_ sql: String) throws -> ResultSet { try run(sql, []) }

    // MARK: Schema

    /// Tables, then views, by name; SQLite's own tables left out.
    func objects() throws -> [DatabaseObject] {
        try run("""
            SELECT type, name FROM sqlite_master
            WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
            ORDER BY type = 'view', name COLLATE NOCASE
            """).rows.compactMap { row in
            guard case .text(let type) = row[0], case .text(let name) = row[1],
                  let kind = DatabaseObject.Kind(rawValue: type) else { return nil }
            return DatabaseObject(name: name, kind: kind)
        }
    }

    func columns(of name: String) throws -> [Column] {
        try run("PRAGMA table_info(\(Database.quote(name)))").rows.map { row in
            Column(name: row[1].display, type: row[2] == .null ? "" : row[2].display,
                   notNull: row[3] == .integer(1), defaultValue: row[4] == .null ? nil : row[4].display,
                   primaryKey: { if case .integer(let n) = row[5] { return Int(n) }; return 0 }())
        }
    }

    func indexes(of name: String) throws -> [Index] {
        try run("PRAGMA index_list(\(Database.quote(name)))").rows.map { row in
            let indexName = row[1].display
            let columns = try run("PRAGMA index_info(\(Database.quote(indexName)))").rows.map { $0[2].display }
            return Index(name: indexName, unique: row[2] == .integer(1), columns: columns)
        }
    }

    /// The CREATE statement for a table, view, index or trigger.
    func createStatement(of name: String) throws -> String? {
        let rows = try run("SELECT sql FROM sqlite_master WHERE name = ?", [.text(name)]).rows
        guard case .text(let sql)? = rows.first?.first else { return nil }
        return sql
    }

    /// Whether rows can be told apart by rowid: true for ordinary tables, false for views
    /// and WITHOUT ROWID tables.
    func hasRowID(_ object: DatabaseObject) -> Bool {
        object.kind == .table && (try? run("SELECT rowid FROM \(Database.quote(object.name)) LIMIT 0")) != nil
    }

    func rowCount(of name: String) throws -> Int {
        guard case .integer(let n)? = try run("SELECT count(*) FROM \(Database.quote(name))").rows.first?.first else { return 0 }
        return Int(n)
    }

    // MARK: Rows

    /// A page of a table's rows. With `rowIDs`, each row's rowid comes first, for editing.
    /// An empty page still has the table's columns.
    func rows(of object: DatabaseObject, orderBy column: String?, ascending: Bool,
              limit: Int, offset: Int, rowIDs: Bool) throws -> ResultSet {
        let select = rowIDs ? "rowid, *" : "*"
        let order = column.map { " ORDER BY \(Database.quote($0)) \(ascending ? "ASC" : "DESC")" } ?? ""
        var page = try run("SELECT \(select) FROM \(Database.quote(object.name))\(order) LIMIT ? OFFSET ?",
                           [.integer(Int64(limit)), .integer(Int64(offset))])
        if page.columns.isEmpty {   // over SSH, an empty result says nothing of its columns
            page.columns = (rowIDs ? ["rowid"] : []) + (try columns(of: object.name)).map(\.name)
        }
        return page
    }

    func update(_ table: String, column: String, to value: Value, rowID: Int64) throws {
        try run("UPDATE \(Database.quote(table)) SET \(Database.quote(column)) = ? WHERE rowid = ?", [value, .integer(rowID)])
    }

    func deleteRows(from table: String, rowIDs: [Int64]) throws {
        guard !rowIDs.isEmpty else { return }
        let marks = Array(repeating: "?", count: rowIDs.count).joined(separator: ", ")
        try run("DELETE FROM \(Database.quote(table)) WHERE rowid IN (\(marks))", rowIDs.map(Value.integer))
    }
}

/// An open SQLite database file on this Mac, through the C API. Free of UI so it can be tested alone.
final class Database: DatabaseConnection {
    let url: URL
    private(set) var readOnly = false
    var name: String { url.lastPathComponent }
    var location: String { url.path }
    var recentKey: String { url.path }
    private var handle: OpaquePointer?

    /// How long to wait for another program's lock before giving up, in seconds.
    static let busyTimeout = 5.0

    /// SQLite copies bound text and blobs right away, so the Swift buffers can go.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens an existing file read-write, falling back to read-only if that's all it allows;
    /// with `create`, makes a new empty database.
    init(url: URL, create: Bool = false) throws {
        self.url = url
        var flags = SQLITE_OPEN_READWRITE
        if create { flags |= SQLITE_OPEN_CREATE }
        if sqlite3_open_v2(url.path, &handle, flags, nil) != SQLITE_OK {
            sqlite3_close_v2(handle)
            handle = nil
            guard !create, sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite"
                sqlite3_close_v2(handle)
                throw DatabaseError(message: message)
            }
            readOnly = true
        }
        // Another program (a Node app with better-sqlite3, say) may be writing; wait for it a while
        // rather than failing at once with "database is locked".
        sqlite3_busy_timeout(handle, Int32(Self.busyTimeout * 1000))
        // Reading the schema fails at once for a file that isn't a database.
        _ = try run("SELECT count(*) FROM sqlite_master")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Whether the first bytes are SQLite's file header.
    static func isDatabaseFile(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        return (try? file.read(upToCount: 16)) == Data("SQLite format 3\0".utf8)
    }

    /// `name` as an SQL identifier, safe whatever characters it has.
    static func quote(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private var lastError: DatabaseError {
        DatabaseError(message: String(cString: sqlite3_errmsg(handle)))
    }

    // MARK: - Running SQL

    @discardableResult
    func run(_ sql: String, _ bindings: [Value]) throws -> ResultSet {
        var result = ResultSet()
        let changesBefore = sqlite3_total_changes(handle)
        try sql.withCString { start in
            var next: UnsafePointer<CChar>? = start
            while let current = next, current.pointee != 0 {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, current, -1, &statement, &next) == SQLITE_OK else { throw lastError }
                guard let statement else { continue }   // only whitespace or a comment was left
                defer { sqlite3_finalize(statement) }
                try bind(bindings, to: statement)
                let rows = try step(statement)
                if sqlite3_column_count(statement) > 0 { result.columns = rows.columns; result.rows = rows.rows }
            }
        }
        result.changes = Int(sqlite3_total_changes(handle) - changesBefore)
        return result
    }

    private func bind(_ values: [Value], to statement: OpaquePointer) throws {
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            let status: Int32
            switch value {
            case .null: status = sqlite3_bind_null(statement, index)
            case .integer(let n): status = sqlite3_bind_int64(statement, index, n)
            case .real(let d): status = sqlite3_bind_double(statement, index, d)
            case .text(let s): status = sqlite3_bind_text(statement, index, s, -1, Self.transient)
            case .blob(let data):
                status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) }
            }
            guard status == SQLITE_OK else { throw lastError }
        }
    }

    private func step(_ statement: OpaquePointer) throws -> (columns: [String], rows: [[Value]]) {
        let count = sqlite3_column_count(statement)
        let columns = (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) }
        var rows: [[Value]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append((0..<count).map { value(statement, $0) })
            case SQLITE_DONE:
                return (columns, rows)
            default:
                throw lastError
            }
        }
    }

    private func value(_ statement: OpaquePointer, _ column: Int32) -> Value {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            let bytes = sqlite3_column_bytes(statement, column)
            guard bytes > 0, let pointer = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: Int(bytes)))
        default: return .null
        }
    }

    /// Adds a row of default values; returns its rowid.
    func insertRow(into table: String) throws -> Int64 {
        try run("INSERT INTO \(Self.quote(table)) DEFAULT VALUES")
        return sqlite3_last_insert_rowid(handle)
    }

}
