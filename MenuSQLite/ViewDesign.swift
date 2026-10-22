import Foundation

/// The SQL behind creating and changing views. SQLite has no ALTER VIEW, so a change drops the
/// view and creates it again, in a transaction.
enum ViewDesign {
    /// A view's definition split from its CREATE VIEW statement: the optional column list and the
    /// SELECT after AS. Quoted names, which may hold "AS" or spaces, are skipped over.
    static func parts(of createStatement: String) -> (columns: String, select: String) {
        let chars = Array(createStatement)
        var i = 0, sawView = false, nameEnd: Int?
        func word(at index: Int) -> String {
            var j = index, w = ""
            while j < chars.count, chars[j].isLetter || chars[j] == "_" { w.append(chars[j]); j += 1 }
            return w.uppercased()
        }
        while i < chars.count {
            let c = chars[i]
            if let close: Character = ["\"": "\"", "'": "'", "`": "`", "[": "]"][c] {
                i += 1
                while i < chars.count, chars[i] != close { i += 1 }
                i += 1
                if sawView, nameEnd == nil { nameEnd = i }
                continue
            }
            if c.isLetter || c == "_" {
                let w = word(at: i)
                let boundary = i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_")
                if boundary, w == "VIEW" { sawView = true }
                else if boundary, sawView, w == "AS", nameEnd != nil {
                    let between = String(chars[nameEnd!..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let select = String(chars[(i + 2)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let columns = between.hasPrefix("(") && between.hasSuffix(")") ? String(between.dropFirst().dropLast()) : ""
                    return (columns.trimmingCharacters(in: .whitespaces), select)
                } else if sawView, nameEnd == nil, !["IF", "NOT", "EXISTS"].contains(w) {
                    nameEnd = i + w.count
                }
                i += max(w.count, 1)
                continue
            }
            i += 1
        }
        return ("", createStatement)
    }

    /// A SELECT without the semicolons a definition can't end in.
    static func trimmed(_ select: String) -> String {
        var s = select.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(";") { s = String(s.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        return s
    }

    /// Creates the view, or replaces `old` with it.
    static func sql(name: String, columns: String, select: String, replacing old: String? = nil) -> String {
        let list = columns.trimmingCharacters(in: .whitespaces)
        let create = "CREATE VIEW \(Database.quote(name))\(list.isEmpty ? "" : " (\(list))") AS\n\(trimmed(select));"
        guard let old else { return create }
        return "BEGIN;\nDROP VIEW \(Database.quote(old));\n\(create)\nCOMMIT;"
    }

    /// The first rows the SELECT gives, to check it before saving.
    static func preview(_ select: String, in database: DatabaseConnection, limit: Int = 50) throws -> ResultSet {
        try database.run("SELECT * FROM (\n\(trimmed(select))\n) LIMIT \(limit)")
    }
}
