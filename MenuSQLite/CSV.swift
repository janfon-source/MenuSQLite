import Foundation

/// CSV (RFC 4180): query results written out, with fields that have commas, quotes or line
/// breaks quoted; and files read in, for importing into a table.
enum CSV {
    /// UTF-8 with a byte-order mark, which Excel needs to read Chinese correctly. Written as
    /// bytes, not Characters, which is several times quicker for a few hundred thousand rows.
    static func data(_ result: ResultSet) -> Data {
        var out: [UInt8] = [0xEF, 0xBB, 0xBF]
        out.reserveCapacity(result.rows.count * max(1, result.columns.count) * 12)
        line(result.columns, into: &out)
        for row in result.rows { line(row.map(\.csv), into: &out) }
        return Data(out)
    }

    private static func line(_ fields: [String], into out: inout [UInt8]) {
        for (i, field) in fields.enumerated() {
            if i > 0 { out.append(UInt8(ascii: ",")) }
            let bytes = field.utf8
            // A comma, a quote or any line break (LF, VT, FF, CR, NEL, LS, PS) means quotes.
            var needsQuotes = false
            var previous: UInt8 = 0, beforePrevious: UInt8 = 0
            for byte in bytes {
                switch byte {
                case 0x2C, 0x22, 0x0A...0x0D: needsQuotes = true
                case 0x85 where previous == 0xC2: needsQuotes = true
                case 0xA8...0xA9 where previous == 0x80 && beforePrevious == 0xE2: needsQuotes = true
                default: break
                }
                if needsQuotes { break }
                beforePrevious = previous
                previous = byte
            }
            guard needsQuotes else {
                out.append(contentsOf: bytes)
                continue
            }
            out.append(0x22)
            for byte in bytes {
                if byte == 0x22 { out.append(0x22) }
                out.append(byte)
            }
            out.append(0x22)
        }
        out.append(contentsOf: [0x0D, 0x0A])
    }

    // MARK: Reading

    /// What a CSV file holds: its rows of fields, and the separator found.
    struct Table {
        var rows: [[String]]
        var separator: Character
    }

    /// The separators a file may use, in the order they're tried.
    static let separators: [Character] = [",", "\t", ";"]

    /// Reads a CSV file's text, whatever it was saved as: UTF-8 (with or without the mark Excel
    /// puts first), UTF-16 with its mark, or else Big5 or GB18030 as older Chinese files are.
    static func text(of data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if let text = String(data: data, encoding: .utf8) { return text }
        for cf in [CFStringEncodings.big5, .GB_18030_2000] {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(data: data, encoding: .isoLatin1)
    }

    /// The separator the first line uses most, outside quotes; a comma if it has none.
    static func guessSeparator(_ text: String) -> Character {
        var counts: [Character: Int] = [:]
        var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            else if !quoted, character.isNewline { break }
            else if !quoted, separators.contains(character) { counts[character, default: 0] += 1 }
        }
        return separators.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) }.flatMap { counts[$0] == nil ? nil : $0 } ?? ","
    }

    /// Splits CSV text into rows of fields. A quoted field may hold the separator, line breaks
    /// and "" for a quote. Blank lines are skipped.
    static func parse(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, wasQuoted = false
        var characters = text.makeIterator()
        var pending: Character?
        func endRow() {
            row.append(field)
            if !(row.count == 1 && row[0].isEmpty && !wasQuoted) { rows.append(row) }
            row = []; field = ""; wasQuoted = false
        }
        while let character = pending ?? characters.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = characters.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"", field.isEmpty {
                quoted = true; wasQuoted = true
            } else if character == separator {
                row.append(field); field = ""
            } else if character.isNewline {   // "\r\n" is one Character
                endRow()
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty || wasQuoted { endRow() }
        return rows
    }
}

