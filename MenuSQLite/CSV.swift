import Foundation

/// Query results as CSV (RFC 4180): fields with commas, quotes or line breaks are quoted.
enum CSV {
    /// UTF-8 with a byte-order mark, which Excel needs to read Chinese correctly.
    static func data(_ result: ResultSet) -> Data {
        var text = line(result.columns)
        for row in result.rows { text += line(row.map(\.csv)) }
        return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    }

    private static func line(_ fields: [String]) -> String {
        fields.map { field in
            field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
                ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                : field
        }.joined(separator: ",") + "\r\n"
    }
}
