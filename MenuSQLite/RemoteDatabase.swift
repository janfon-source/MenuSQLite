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
    /// sqlite3 older than quote mode (CentOS 7 has 3.7.17) prints CSV instead, which loses some
    /// types: quoted values read as text and bare numbers as numbers, and BLOBs come out as
    /// their raw bytes.
    private(set) var csvOutput = false
    /// Old sqlite3 has no -readonly option either.
    private var hasReadOnlyOption = true

    var name: String { (remote.path as NSString).lastPathComponent }
    var location: String { "\(remote.destination):\(remote.path)" }
    var recentKey: String { remote.key }

    /// The ssh program; tests point it at a stand-in that runs the command locally.
    static var sshPath = "/usr/bin/ssh"
    /// For tests: read output as old sqlite3 would print it, even from a newer one.
    static var forceCSVOutput = false
    static let timeout: TimeInterval = 30

    /// Connects and checks the file: that it's there and readable, whether it's writable,
    /// and that the server has sqlite3.
    init(_ remote: RemoteLocation) throws {
        self.remote = remote
        // Each answer is a line: what was found, then details. "Missing" is told apart from a
        // folder this account can't get into, which hides what's in it just the same.
        let check = """
            p=\(Self.shellQuote(remote.path))
            echo "WHO $(whoami)@$(hostname)"
            command -v sqlite3 >/dev/null 2>&1 || { echo NOSQLITE; exit 0; }
            printf '.mode quote\\n' | sqlite3 :memory: 2>&1 | grep -q Error && echo NOQUOTE
            sqlite3 -help 2>&1 | grep -q -- -readonly || echo NOREADONLY
            d=$(dirname "$p")
            if [ ! -e "$p" ]; then
              while [ "$d" != / ] && [ ! -d "$d" ]; do d=$(dirname "$d"); done
              if [ -x "$d" ] && [ -r "$d" ]; then
                echo MISSING
                ls -1 "$d" 2>/dev/null | grep -iE '[.](sqlite3?|sqllite|db3?|s3db)$' | head -8 | sed 's/^/FILE /'
              else
                echo "NOACCESS $d"
              fi
              exit 0
            fi
            [ -f "$p" ] || { echo NOTFILE; exit 0; }
            [ -r "$p" ] || { echo UNREADABLE; exit 0; }
            # Changing a database also needs its folder, for the journal SQLite writes beside it.
            if [ -w "$p" ] && [ -w "$d" ]; then echo WRITABLE; else echo READONLY; fi
            """
        let lines = try ssh(command: "sh -s", input: check).split(separator: "\n").map(String.init)
        func field(_ name: String) -> String? {
            lines.first { $0 == name || $0.hasPrefix(name + " ") }.map { String($0.dropFirst(name.count)).trimmingCharacters(in: .whitespaces) }
        }
        let who = field("WHO") ?? remote.destination
        let path = remote.path
        if field("NOSQLITE") != nil {
            throw DatabaseError(message: tr("\(who) 上沒有 sqlite3 指令，請先安裝（例如 apt install sqlite3）。",
                                            "\(who) has no sqlite3 command. Install it first (apt install sqlite3, for example)."))
        }
        if field("MISSING") != nil {
            let nearby = lines.filter { $0.hasPrefix("FILE ") }.map { String($0.dropFirst(5)) }
            var message = tr("在 \(who) 上找不到「\(path)」。", "“\(path)” isn’t on \(who).")
            if !nearby.isEmpty {
                message += "\n" + tr("同一個資料夾裡的資料庫檔案：", "Database files in the same folder: ") + nearby.joined(separator: tr("、", ", "))
            }
            throw DatabaseError(message: message)
        }
        if let folder = field("NOACCESS") {
            throw DatabaseError(message: tr("以 \(who) 登入，沒有權限進入「\(folder)」資料夾，所以看不到裡面的檔案。請讓這個帳號可以讀取並進入該資料夾（r 和 x 權限），或改用有權限的帳號連線。",
                                            "Signed in as \(who), which can’t get into “\(folder)”, so the files in it can’t be seen. Give this account read and search (r and x) permission on that folder, or connect as an account that has it."))
        }
        if field("NOTFILE") != nil {
            throw DatabaseError(message: tr("「\(path)」不是檔案。", "“\(path)” isn’t a file."))
        }
        if field("UNREADABLE") != nil {
            throw DatabaseError(message: tr("以 \(who) 登入，沒有讀取「\(path)」的權限。", "Signed in as \(who), which can’t read “\(path)”."))
        }
        readOnly = field("READONLY") != nil
        csvOutput = field("NOQUOTE") != nil || Self.forceCSVOutput
        hasReadOnlyOption = field("NOREADONLY") == nil
        _ = try run("SELECT count(*) FROM sqlite_master")   // a file that isn't a database fails here
    }

    // MARK: Running SQL

    private static let marker = "@@MENUSQLITE@@"
    /// What CSV output prints for NULL, which an empty string can't be told from otherwise.
    private static let nullMarker = "@@MENUSQLITE-NULL@@"

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
        let statements = Self.statements(in: bindings.isEmpty ? sql : Database.inline(bindings, into: sql))
        // .timeout: wait for another program's lock, as on this Mac, rather than failing at once.
        var script = ".bail on\n.timeout \(Int(Database.busyTimeout * 1000))\n.headers on\n" + (csvOutput ? ".mode csv\n.nullvalue \(Self.nullMarker)\n" : ".mode quote\n")
        for statement in statements {
            script += ".print \(Self.marker)\n" + statement + (statement.hasSuffix(";") ? "" : ";") + "\n"
        }
        script += ".print \(Self.marker)\nSELECT total_changes(), last_insert_rowid();\n"
        let command = "sqlite3 -batch\(readOnly && hasReadOnlyOption ? " -readonly" : "") \(Self.shellQuote(remote.path))"
        let output = try ssh(command: command, input: script)

        // What came before the first marker isn't ours; then one section per statement, and the counts.
        let sections = output.components(separatedBy: Self.marker + "\n").dropFirst()
            .map { csvOutput ? Self.parseCSV($0) : Self.parse($0) }
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

    /// Rows as old sqlite3's `.mode csv` prints them, NULL as `nullMarker`. A quoted field is
    /// text; a bare one is a number if it reads as one, and text otherwise.
    static func parseCSV(_ text: String) -> [[Value]] {
        var rows: [[Value]] = [], row: [Value] = [], field = "", quoted = false, inQuotes = false, started = false
        func endField() {
            if quoted { row.append(.text(field)) }
            else if field == nullMarker { row.append(.null) }
            else if let n = Int64(field) { row.append(.integer(n)) }
            else if let d = Double(field), field.contains(where: { ".eE".contains($0) }) { row.append(.real(d)) }
            else { row.append(.text(field)) }
            field = ""; quoted = false; started = false
        }
        var chars = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && !started {
                inQuotes = true; quoted = true; started = true
            } else if c == "," {
                endField()
            } else if c == "\n" || c == "\r\n" {
                if started || !row.isEmpty || !field.isEmpty { endField(); rows.append(row) }
                row = []
            } else if c != "\r" {
                field.append(c); started = true
            }
        }
        if started || !row.isEmpty { endField(); rows.append(row) }
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
        if let range = message.range(of: #"^((Parse|Runtime) error|Error):? (near line \d+: )?"#, options: .regularExpression) {
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
