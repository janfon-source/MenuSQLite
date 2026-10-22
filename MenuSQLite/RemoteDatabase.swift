import Foundation
import SQLite3

/// Where a database on a server is: how to reach the server over SSH, and the file's path there.
struct RemoteLocation: Equatable {
    /// `user@host`, or a Host name from ~/.ssh/config.
    var destination: String
    var port: Int?
    /// On the server; may start with `~/`.
    var path: String
    /// A private key file on this Mac, when not the default one or the agent's.
    var identity: String?

    /// How the recent list stores it: ssh://destination:port?path=…&identity=…, each part
    /// percent-encoded. Built by hand: URLComponents rejects Host names such as asia_db, and
    /// "user@host" isn't a host to it.
    var key: String {
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        return "ssh://" + encode(destination) + (port.map { ":\($0)" } ?? "") + "?path=" + encode(path)
            + (identity.map { "&identity=" + encode($0) } ?? "")
    }

    init(destination: String, port: Int? = nil, path: String, identity: String? = nil) {
        self.destination = destination
        self.port = port
        self.path = path
        self.identity = identity
    }

    init?(key: String) {
        guard key.hasPrefix("ssh://") else { return nil }
        let rest = key.dropFirst(6)
        let address = rest.prefix { $0 != "?" }
        var fields: [String: String] = [:]
        for pair in rest.dropFirst(address.count + 1).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1].removingPercentEncoding }
        }
        let host = address.split(separator: ":", maxSplits: 1).map(String.init)
        guard let destination = host.first?.removingPercentEncoding, !destination.isEmpty,
              let path = fields["path"], !path.isEmpty else { return nil }
        self.destination = destination
        port = host.count > 1 ? Int(host[1]) : nil
        self.path = path
        identity = fields["identity"]
    }
}

/// A database on a server, used by running the server's `sqlite3` over SSH. The file stays where
/// it is: every query and change runs there, so nothing is copied back and forth. SSH's
/// connection sharing keeps one connection open, so later commands start quickly.
final class RemoteDatabase: DatabaseConnection {
    let remote: RemoteLocation
    private(set) var readOnly = false

    var name: String { (remote.path as NSString).lastPathComponent }
    var location: String { "\(remote.destination):\(remote.path)" }
    var recentKey: String { remote.key }

    /// The ssh program; tests point it at a stand-in that runs the command locally.
    static var sshPath = "/usr/bin/ssh"
    static let timeout: TimeInterval = 30

    /// Connects and checks the file: that it's there and readable, whether it's writable,
    /// and that the server has sqlite3.
    init(_ remote: RemoteLocation) throws {
        self.remote = remote
        let path = Self.shellQuote(remote.path)
        let check = """
            command -v sqlite3 >/dev/null 2>&1 || { echo NOSQLITE; exit 0; }
            [ -f \(path) ] || { echo MISSING; exit 0; }
            [ -r \(path) ] || { echo UNREADABLE; exit 0; }
            [ -w \(path) ] && echo WRITABLE || echo READONLY
            """
        let reply = try ssh(command: "sh -s", input: check).trimmingCharacters(in: .whitespacesAndNewlines)
        switch reply {
        case "NOSQLITE":
            throw DatabaseError(message: tr("伺服器上沒有 sqlite3 指令，請先安裝（例如 apt install sqlite3）。",
                                            "The server has no sqlite3 command. Install it first (apt install sqlite3, for example)."))
        case "MISSING":
            throw DatabaseError(message: tr("伺服器上找不到「\(remote.path)」。", "“\(remote.path)” isn’t on the server."))
        case "UNREADABLE":
            throw DatabaseError(message: tr("沒有讀取「\(remote.path)」的權限。", "No permission to read “\(remote.path)”."))
        case "READONLY":
            readOnly = true
        default:
            break
        }
        _ = try run("SELECT count(*) FROM sqlite_master")   // a file that isn't a database fails here
    }

    // MARK: Running SQL

    private static let marker = "@@MENUSQLITE@@"

    @discardableResult
    func run(_ sql: String, _ bindings: [Value]) throws -> ResultSet {
        try execute(sql, bindings).result
    }

    func insertRow(into table: String) throws -> Int64 {
        try execute("INSERT INTO \(Database.quote(table)) DEFAULT VALUES", []).lastRowID
    }

    /// Sends the statements to sqlite3 on the server, each after a marker line so their output
    /// can be told apart, then asks how many rows changed and the last inserted rowid.
    private func execute(_ sql: String, _ bindings: [Value]) throws -> (result: ResultSet, lastRowID: Int64) {
        let statements = Self.statements(in: bindings.isEmpty ? sql : Self.inline(bindings, into: sql))
        var script = ".bail on\n.headers on\n.mode quote\n"
        for statement in statements {
            script += ".print \(Self.marker)\n" + statement + (statement.hasSuffix(";") ? "" : ";") + "\n"
        }
        script += ".print \(Self.marker)\nSELECT total_changes(), last_insert_rowid();\n"
        let command = "sqlite3 -batch\(readOnly ? " -readonly" : "") \(Self.shellQuote(remote.path))"
        let output = try ssh(command: command, input: script)

        // What came before the first marker isn't ours; then one section per statement, and the counts.
        let sections = output.components(separatedBy: Self.marker + "\n").dropFirst().map { Self.parse($0) }
        var result = ResultSet()
        for section in sections.dropLast() where !section.isEmpty {
            result.columns = section[0].map(\.display)
            result.rows = Array(section.dropFirst())
        }
        var lastRowID: Int64 = 0
        if let counts = sections.last, counts.count > 1 {
            if case .integer(let n) = counts[1][0] { result.changes = Int(n) }
            if case .integer(let id) = counts[1][1] { lastRowID = id }
        }
        return (result, lastRowID)
    }

    /// Splits SQL into statements where SQLite itself would, so a ";" inside a string doesn't.
    static func statements(in sql: String) -> [String] {
        var statements: [String] = [], current = ""
        for character in sql {
            current.append(character)
            if character == ";", sqlite3_complete(current) != 0 {
                statements.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statements.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return statements
    }

    /// Puts the values in place of the `?` placeholders, since the command line can't bind them.
    /// Only for the app's own statements, whose `?`s are never inside strings.
    private static func inline(_ values: [Value], into sql: String) -> String {
        var values = values[...]
        return sql.reduce(into: "") { out, character in
            if character == "?", let value = values.popFirst() { out += value.sqlLiteral } else { out.append(character) }
        }
    }

    // MARK: Reading sqlite3's quote mode

    /// Rows of comma-separated SQL literals, a row per line, as `.mode quote` prints them:
    /// NULL, numbers, 'text' (with '' for a quote), unistr('…') for text with control
    /// characters, and x'hex' for BLOBs.
    static func parse(_ text: String) -> [[Value]] {
        var rows: [[Value]] = [], row: [Value] = []
        var i = text.startIndex
        func peek(_ offset: Int = 0) -> Character? {
            guard let j = text.index(i, offsetBy: offset, limitedBy: text.endIndex), j < text.endIndex else { return nil }
            return text[j]
        }
        /// A 'quoted' string starting at i, with '' standing for a quote.
        func quoted() -> String {
            var s = ""
            i = text.index(after: i)
            while i < text.endIndex {
                if text[i] == "'" {
                    if peek(1) == "'" { s.append("'"); i = text.index(i, offsetBy: 2); continue }
                    i = text.index(after: i)
                    break
                }
                s.append(text[i])
                i = text.index(after: i)
            }
            return s
        }
        while i < text.endIndex {
            let c = text[i]
            if c == "\n" {
                if !row.isEmpty { rows.append(row) }
                row = []
                i = text.index(after: i)
            } else if c == "," || c == " " || c == "\r" {
                i = text.index(after: i)
            } else if c == "'" {
                row.append(.text(quoted()))
            } else if (c == "x" || c == "X"), peek(1) == "'" {
                i = text.index(after: i)
                row.append(.blob(hexData(quoted())))
            } else if text[i...].hasPrefix("unistr('") {
                i = text.index(i, offsetBy: 7)
                row.append(.text(unescape(quoted())))
                if i < text.endIndex, text[i] == ")" { i = text.index(after: i) }
            } else {
                var word = ""
                while i < text.endIndex, !",\n\r".contains(text[i]) { word.append(text[i]); i = text.index(after: i) }
                if word == "NULL" { row.append(.null) }
                else if let n = Int64(word) { row.append(.integer(n)) }
                else if let d = Double(word) { row.append(.real(d)) }
                else { row.append(.text(word)) }
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    private static func hexData(_ hex: String) -> Data {
        var data = Data(), digits = hex.makeIterator()
        while let high = digits.next(), let low = digits.next(), let byte = UInt8(String([high, low]), radix: 16) {
            data.append(byte)
        }
        return data
    }

    /// unistr()'s escapes: \XXXX or \uXXXX, \+XXXXXX, \UXXXXXXXX, and \\ for a backslash.
    private static func unescape(_ s: String) -> String {
        var out = "", chars = Array(s), i = 0
        while i < chars.count {
            guard chars[i] == "\\", i + 1 < chars.count else { out.append(chars[i]); i += 1; continue }
            let next = chars[i + 1]
            let (skip, length): (Int, Int) = next == "\\" ? (2, 0) : next == "u" ? (2, 4) : next == "+" ? (2, 6) : next == "U" ? (2, 8) : (1, 4)
            if length == 0 { out.append("\\"); i += 2; continue }
            let digits = String(chars[min(chars.count, i + skip)..<min(chars.count, i + skip + length)])
            if digits.count == length, let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) {
                out.unicodeScalars.append(scalar)
                i += skip + length
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    // MARK: SSH

    /// Runs a command on the server, with `input` on its standard input; returns what it printed.
    private func ssh(command: String, input: String) throws -> String {
        var arguments = [
            "-o", "BatchMode=yes",                        // never stop to ask for a password
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=10",
            "-o", "ControlMaster=auto",                   // share one connection between commands
            "-o", "ControlPath=/tmp/menusqlite-%C",
            "-o", "ControlPersist=120",
        ]
        if let port = remote.port { arguments += ["-p", String(port)] }
        if let identity = remote.identity, !identity.isEmpty {
            arguments += ["-i", (identity as NSString).expandingTildeInPath]
        }
        arguments += [remote.destination, command]

        // Files rather than pipes for the output, so a large result can't fill a pipe and stall.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("menusqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inURL = folder.appendingPathComponent("in"), outURL = folder.appendingPathComponent("out"),
            errURL = folder.appendingPathComponent("err")
        try Data(input.utf8).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sshPath)
        process.arguments = arguments
        process.standardInput = try FileHandle(forReadingFrom: inURL)
        process.standardOutput = try FileHandle(forWritingTo: outURL)
        process.standardError = try FileHandle(forWritingTo: errURL)
        try process.run()
        let deadline = Date().addingTimeInterval(Self.timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw DatabaseError(message: tr("伺服器沒有回應（超過 \(Int(Self.timeout)) 秒）。",
                                                "The server didn’t answer within \(Int(Self.timeout)) seconds."))
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let output = String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self)
        let errors = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw DatabaseError(message: Self.cleanError(errors, status: process.terminationStatus)) }
        return output
    }

    /// sqlite3's and ssh's messages, without the parts that don't help: "Parse error near line 9:".
    private static func cleanError(_ text: String, status: Int32) -> String {
        let lines = text.split(separator: "\n").map(String.init).filter {
            !$0.hasPrefix("Warning: Permanently added") && !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard var message = lines.first else { return tr("SSH 連線失敗（代碼 \(status)）。", "The SSH connection failed (code \(status)).") }
        if let range = message.range(of: #"^(Parse|Runtime) error near line \d+: |^Error: (near line \d+: )?"#, options: .regularExpression) {
            message.removeSubrange(range)
        }
        if message.contains("Permission denied") {
            message += "\n" + tr("隨手庫用 SSH 金鑰或 ssh-agent 登入，不會詢問密碼；請先設定好金鑰登入。",
                                 "MenuSQLite signs in with SSH keys or ssh-agent and never asks for a password; set up key login first.")
        }
        return message
    }

    /// `path` quoted for the server's shell, keeping a leading ~/ so it still means the home folder.
    static func shellQuote(_ path: String) -> String {
        let home = path.hasPrefix("~/")
        let rest = home ? String(path.dropFirst(2)) : path
        return (home ? "~/" : "") + "'" + rest.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
