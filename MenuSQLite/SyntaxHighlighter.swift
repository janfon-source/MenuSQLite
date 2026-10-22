import AppKit

/// Colors the code in a fenced block by its language, with a few regular expressions per language.
/// Not a parser: it knows comments, strings, keywords, numbers and some names, which is enough
/// to make a snippet in a note easy to read.
enum SyntaxHighlighter {
    private enum Token {
        case comment, string, keyword, number, type, function, attribute
        /// An HTML tag, colored piece by piece with `tagGrammar`.
        case tag
    }

    /// Xcode's default colors, for light and dark appearance.
    private static func color(_ token: Token) -> NSColor {
        switch token {
        case .comment: return dynamic(0x5D6C79, 0x6C7986)
        case .string: return dynamic(0xC41A16, 0xFC6A5D)
        case .keyword, .tag: return dynamic(0x9B2393, 0xFC5FA3)
        case .number: return dynamic(0x1C00CF, 0xD0BF69)
        case .type: return dynamic(0x0B4F79, 0x5DD8FF)
        case .function: return dynamic(0x326D74, 0x67B7A4)
        case .attribute: return dynamic(0x815F03, 0xFD8F3F)
        }
    }

    private static func dynamic(_ light: Int, _ dark: Int) -> NSColor {
        func rgb(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light) }
    }

    /// One language's rules joined into a single pattern, so the text is scanned once from left
    /// to right and a "#" inside a string never starts a comment. Where two rules match at the
    /// same place, the earlier one wins. Rules must use only non-capturing groups.
    private struct Grammar {
        let regex: NSRegularExpression
        let tokens: [Token]

        init(_ rules: [(Token, String)]) {
            regex = try! NSRegularExpression(pattern: rules.map { "(\($0.1))" }.joined(separator: "|"))
            tokens = rules.map(\.0)
        }
    }

    static func highlight(_ code: NSMutableAttributedString, language: String?) {
        guard let name = language?.lowercased(), let grammar = grammars[aliases[name] ?? name] else { return }
        apply(grammar, to: code, in: NSRange(location: 0, length: code.length))
    }

    private static func apply(_ grammar: Grammar, to code: NSMutableAttributedString, in range: NSRange) {
        grammar.regex.enumerateMatches(in: code.string, range: range) { match, _, _ in
            guard let match else { return }
            for (i, token) in grammar.tokens.enumerated() {
                let r = match.range(at: i + 1)
                guard r.location != NSNotFound else { continue }
                if token == .tag {
                    apply(tagGrammar, to: code, in: r)
                } else {
                    code.addAttribute(.foregroundColor, value: color(token), range: r)
                }
                break
            }
        }
    }

    // MARK: - Languages

    private static let aliases = [
        "py": "python", "python3": "python",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "node": "javascript",
        "ts": "javascript", "tsx": "javascript", "typescript": "javascript",
        "sh": "bash", "zsh": "bash", "shell": "bash", "console": "bash", "shellscript": "bash",
        "htm": "html", "xhtml": "html", "xml": "html", "svg": "html",
        "scss": "css", "less": "css",
        "jsonc": "json", "json5": "json",
        "h": "c",
        "c++": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
        "mysql": "sql", "postgres": "sql", "postgresql": "sql", "sqlite": "sql", "plsql": "sql",
    ]

    private static func words(_ list: String) -> String {
        #"\b(?:"# + list.split(separator: " ").joined(separator: "|") + #")\b"#
    }

    private static let doubleQuoted = #""(?:\\.|[^"\\\n])*""#
    private static let singleQuoted = #"'(?:\\.|[^'\\\n])*'"#
    private static let cComment = #"//[^\n]*|/\*[\s\S]*?\*/"#
    private static let number = #"\b(?:0[xX][0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?[lLfFdDn]?)\b"#
    private static let capitalized = #"\b[A-Z][A-Za-z0-9_]*\b"#
    private static let call = #"\b[A-Za-z_$][\w$]*(?=\s*\()"#

    private static let cKeywords = "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while _Bool bool true false NULL"
    private static let cppKeywords = cKeywords + " alignas alignof asm catch char8_t char16_t char32_t class concept consteval constexpr constinit const_cast co_await co_return co_yield decltype delete dynamic_cast explicit export final friend mutable namespace new noexcept nullptr operator override private protected public reinterpret_cast requires static_assert static_cast template this thread_local throw try typeid typename using virtual wchar_t"

    /// C and C++ differ only in their keywords and the library names worth coloring.
    private static func cFamily(keywords: String, types: String) -> Grammar {
        Grammar([
            (.comment, cComment),
            (.attribute, #"(?m)^[ \t]*#[ \t]*[A-Za-z]+"#),   // preprocessor directives
            (.string, #"(?<=include)[ \t]*<[^>\n]*>"#),       // <stdio.h> after #include
            (.string, #"(?:\b(?:u8|u|U|L))?"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])+'"#),
            (.keyword, words(keywords)),
            (.type, words(types)),
            (.type, capitalized),
            (.number, #"\b(?:0[xX][0-9a-fA-F']+|0[bB][01']+|\d[\d']*(?:\.\d+)?(?:[eE][+-]?\d+)?)[uUlLfF]*\b"#),
            (.function, call),
        ])
    }

    private static let tagGrammar = Grammar([
        (.string, doubleQuoted + "|" + singleQuoted),
        (.keyword, #"</?[A-Za-z][\w:.-]*|/?>"#),
        (.attribute, #"[A-Za-z_:@][\w:.-]*"#),
    ])

    private static let grammars: [String: Grammar] = [
        "python": Grammar([
            (.comment, #"#[^\n]*"#),
            (.string, #"(?:\b[rRbBuUfF]{1,2})?(?:"""[\s\S]*?"""|'''[\s\S]*?'''|"# + doubleQuoted + "|" + singleQuoted + ")"),
            (.attribute, #"@[A-Za-z_][\w.]*"#),
            (.keyword, words("False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case self cls")),
            (.type, words("print len range int str float list dict set tuple bool bytes open type isinstance enumerate zip map filter sorted sum min max abs super object Exception")),
            (.type, capitalized),
            (.number, number),
            (.function, call),
        ]),
        "javascript": Grammar([
            (.comment, cComment),
            (.string, doubleQuoted + "|" + singleQuoted + #"|`(?:\\.|[^`\\])*`"#),
            (.keyword, words("break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new of return super switch this throw try typeof var void while with yield async await static get set from as null undefined true false NaN Infinity interface type enum implements private public protected readonly")),
            (.type, capitalized),
            (.number, number),
            (.function, call),
        ]),
        "java": Grammar([
            (.comment, cComment),
            (.string, #""""[\s\S]*?"""|"# + doubleQuoted + "|" + singleQuoted),
            (.attribute, #"@[A-Za-z_]\w*"#),
            (.keyword, words("abstract assert boolean break byte case catch char class continue default do double else enum extends final finally float for if implements import instanceof int interface long native new package private protected public record return short static super switch synchronized this throw throws transient try var void volatile while yield true false null")),
            (.type, capitalized),
            (.number, number),
            (.function, call),
        ]),
        "sql": Grammar([
            (.comment, #"--[^\n]*|/\*[\s\S]*?\*/"#),
            (.string, #"'(?:''|[^'])*'"#),
            (.type, #""[^"\n]*"|`[^`\n]*`"#),   // quoted identifiers
            (.keyword, "(?i:" + words("select from where and or not in is null as join inner left right full outer cross on group by order having limit offset union all distinct insert into values update set delete create table view index drop alter add column primary key foreign references unique default constraint if exists case when then else end asc desc like between with returning begin commit rollback transaction true false") + ")"),
            (.type, "(?i:" + words("int integer bigint smallint tinyint decimal numeric float real double varchar char text boolean bool date time timestamp datetime blob json serial uuid") + ")"),
            (.number, number),
            (.function, call),
        ]),
        "bash": Grammar([
            (.comment, #"(?<!\S)#[^\n]*"#),
            (.string, #""(?:\\.|[^"\\])*"|'[^']*'"#),
            (.attribute, #"\$(?:\{[^}\n]*\}|\w+|[@#?$!*0-9-])"#),
            (.keyword, words("if then else elif fi for while until do done case esac in function return local export select break continue")),
            (.function, words("echo cd pwd ls cat grep sed awk find mkdir rm cp mv chmod chown exit source alias unset read printf test eval exec set shift trap sudo curl git npm brew")),
            (.type, #"(?<!\S)--?[A-Za-z][\w-]*"#),   // options
            (.number, #"\b\d+\b"#),
        ]),
        "html": Grammar([
            (.comment, #"<!--[\s\S]*?-->|<![A-Za-z][^>]*>"#),
            (.tag, #"</?[A-Za-z][^>]*>"#),
            (.number, #"&[#\w]+;"#),   // entities
        ]),
        "css": Grammar([
            (.comment, #"/\*[\s\S]*?\*/"#),
            (.string, doubleQuoted + "|" + singleQuoted),
            (.keyword, #"@[\w-]+|!important"#),
            (.attribute, #"[\w-]+(?=\s*:[^;{}]*[;}])"#),   // property names, not "a:hover {"
            (.number, #"#[0-9a-fA-F]{3,8}\b|(?<![\w-])-?\d*\.?\d+(?:[a-zA-Z%]+)?"#),
            (.function, #"[\w-]+(?=\()"#),
            (.type, #"[.#][A-Za-z_-][\w-]*"#),   // class and id selectors
        ]),
        "php": Grammar([
            (.attribute, #"#\[[^\]\n]*\]"#),   // PHP 8 attributes, before "#" starts a comment
            (.comment, cComment + #"|#[^\n]*"#),
            (.string, #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#),
            (.keyword, #"<\?(?:php|=)?|\?>"#),
            (.attribute, #"\$\w+"#),   // variables
            // PHP keywords ignore case.
            (.keyword, "(?i:" + words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield self parent true false null") + ")"),
            (.type, words("int float string bool void mixed object iterable never")),
            (.type, capitalized),
            (.number, number),
            (.function, call),
        ]),
        "c": cFamily(keywords: cKeywords,
                     types: "size_t ssize_t ptrdiff_t intptr_t uintptr_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t FILE"),
        "cpp": cFamily(keywords: cppKeywords,
                       types: "size_t ptrdiff_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t std string string_view vector array map unordered_map set unordered_set list deque pair tuple optional variant shared_ptr unique_ptr weak_ptr function cout cin cerr endl"),
        "json": Grammar([
            (.attribute, doubleQuoted + #"(?=\s*:)"#),   // keys
            (.string, doubleQuoted),
            (.keyword, words("true false null")),
            (.number, #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#),
        ]),
    ]
}
