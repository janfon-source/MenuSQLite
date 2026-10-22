import AppKit

/// HackMD's additions to Markdown that Apple's parser doesn't know.
///
/// `rewrite` runs on the source before parsing. It turns block syntax into plain Markdown the parser
/// understands, with private-use characters marking what the renderer should style:
/// - `:::info` / `success` / `warning` / `danger` boxes and `:::spoiler Title` become quotes whose
///   first paragraph is a marker (`containerMarker` or `spoilerMarker` and the kind or title).
/// - A `[TOC]` line becomes `tocMarker`, which the renderer replaces with the headings.
/// - Footnote references `[^id]` and inline footnotes `^[text]` become numbered markers, and the
///   footnotes are listed after a rule at the end.
/// - Front matter, HTML comments and abbreviation definitions (`*[HTML]: …`) are removed.
/// - `:emoji:` shortcodes become emoji, and `{%youtube id %}`-style embeds become links.
enum HackMD {
    static let containerMarker: Character = "\u{E020}"
    static let spoilerMarker: Character = "\u{E021}"
    static let tocMarker: Character = "\u{E022}"
    static let footnoteReference = ("\u{E023}", "\u{E024}")   // around the footnote's number
    static let footnoteAnchor = ("\u{E026}", "\u{E027}")      // at the start of the footnote itself

    /// Starts the image URL fragment that carries what the parser would drop: `size=200x100` and
    /// `link=…`, joined by "&" (see MarkdownRenderer.imageOptions).
    static let imageOptionPrefix = "menunote-"

    /// Where a link in the preview jumps to, by the `anchor` attribute value of its target.
    static let anchorScheme = "menunote-anchor"
    static let spoilerScheme = "menunote-spoiler"
    static let anchor = NSAttributedString.Key("MenuNoteAnchor")

    /// What the rewrite learned that the renderer needs.
    struct Notes {
        var abbreviations: [(term: String, title: String)] = []
    }

    // MARK: - Source

    private static let containerOpen = try! NSRegularExpression(pattern: #"^:::[ \t]*(info|success|warning|danger|spoiler|menunote-center|menunote-right|menunote-quote)\b[ \t]*(.*)$"#)
    private static let footnoteDefinition = try! NSRegularExpression(pattern: #"^\[\^([^\]\s]+)\]:[ \t]?(.*)$"#)
    private static let abbreviationDefinition = try! NSRegularExpression(pattern: #"^\*\[([^\]]+)\]:[ \t]*(.+)$"#)
    private static let footnoteRef = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]|\^\[([^\]]+)\]"#)
    private static let emojiCode = try! NSRegularExpression(pattern: #":([a-z0-9_+\-]+):"#)
    private static let sizedImage = try! NSRegularExpression(pattern: #"(!\[[^\]]*\]\()([^)\s]+)[ \t]+=(\d*)x(\d*)\)"#)
    private static let linkedImage = try! NSRegularExpression(pattern: #"\[(!\[[^\]]*\]\()([^)\s]+)\)\]\(([^)\s]+)\)"#)
    private static let embed = try! NSRegularExpression(pattern: #"\{%[ \t]*(\w+)[ \t]+(\S+?)[ \t]*%\}"#)
    private static let codeSpan = try! NSRegularExpression(pattern: "(`+).*?\\1")

    private static func match(_ regex: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    }
    private static func group(_ m: NSTextCheckingResult, _ i: Int, in line: String) -> String? {
        m.range(at: i).location == NSNotFound ? nil : (line as NSString).substring(with: m.range(at: i))
    }

    /// Applies `transform` to the parts of a line outside inline code.
    static func outsideCode(_ line: String, _ transform: (String) -> String) -> String {
        let ns = line as NSString
        var out = "", start = 0
        for code in codeSpan.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out += transform(ns.substring(with: NSRange(location: start, length: code.range.location - start)))
            out += ns.substring(with: code.range)
            start = NSMaxRange(code.range)
        }
        return out + transform(ns.substring(from: start))
    }

    static func rewrite(_ source: String) -> (String, Notes) {
        var notes = Notes()
        var lines = withoutComments(withoutFrontMatter(source.components(separatedBy: "\n")))

        // Footnote and abbreviation definitions can come anywhere; collect them first.
        var footnoteTexts: [String: String] = [:]
        var fences = FenceTracker()
        lines = lines.filter { line in
            if fences.isFence(line) || fences.inside { return true }
            if let m = match(footnoteDefinition, line) {
                footnoteTexts[group(m, 1, in: line)!] = group(m, 2, in: line) ?? ""
                return false
            }
            if let m = match(abbreviationDefinition, line) {
                notes.abbreviations.append((group(m, 1, in: line)!, group(m, 2, in: line)!))
                return false
            }
            return true
        }

        var out: [String] = []
        var footnotes: [String] = []        // footnote texts, numbered by first reference
        var numbers: [String: Int] = [:]    // footnote id → number
        var depth = 0                       // containers open around this line
        fences = FenceTracker()
        func quoted(_ line: String, _ level: Int) -> String {
            level == 0 ? line : String(repeating: "> ", count: level) + line
        }
        /// A line that ends the paragraph or quote before it, inside `level` containers.
        func separator(_ level: Int) -> String { String(repeating: ">", count: level) }

        for line in lines {
            if fences.isFence(line) || fences.inside {
                out.append(quoted(line, depth))
                continue
            }
            if let m = match(containerOpen, line) {
                let kind = group(m, 1, in: line)!
                let title = group(m, 2, in: line) ?? ""
                out.append(separator(depth))
                depth += 1
                out.append(quoted(kind == "spoiler" ? "\(spoilerMarker)\(title)" : "\(containerMarker)\(kind)", depth))
                out.append(separator(depth))
                continue
            }
            if depth > 0, line.trimmingCharacters(in: .whitespaces) == ":::" {
                depth -= 1
                out.append(separator(depth))
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).uppercased() == "[TOC]" {
                out.append(quoted(String(tocMarker), depth))
                continue
            }
            out.append(quoted(outsideCode(line) { text in
                inline(text, footnoteTexts: footnoteTexts, footnotes: &footnotes, numbers: &numbers)
            }, depth))
        }

        if !footnotes.isEmpty {
            out += ["", "---", ""]
            for (i, text) in footnotes.enumerated() {
                out.append("\(i + 1). \(footnoteAnchor.0)\(i + 1)\(footnoteAnchor.1)\(text)")
            }
        }
        return (out.joined(separator: "\n"), notes)
    }

    /// Front matter: a block between "---" lines at the very top, which HackMD reads as settings.
    private static func withoutFrontMatter(_ lines: [String]) -> [String] {
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return lines }
        return Array(lines[(end + 1)...])
    }

    /// HTML comments, which HackMD hides, possibly over several lines; code keeps them.
    private static func withoutComments(_ lines: [String]) -> [String] {
        var out: [String] = []
        var fences = FenceTracker()
        var inComment = false
        for line in lines {
            if !inComment, fences.isFence(line) || fences.inside { out.append(line); continue }
            let ns = line as NSString
            let code = codeSpan.matches(in: line, range: NSRange(location: 0, length: ns.length)).map(\.range)
            /// The first `token` at or after `from` that isn't inside inline code.
            func find(_ token: String, from: Int) -> NSRange? {
                var start = from
                while start < ns.length {
                    let r = ns.range(of: token, range: NSRange(location: start, length: ns.length - start))
                    guard r.location != NSNotFound else { return nil }
                    guard let span = code.first(where: { NSLocationInRange(r.location, $0) }) else { return r }
                    start = NSMaxRange(span)
                }
                return nil
            }
            var position = 0, kept = ""
            while position < ns.length {
                if inComment {
                    guard let end = ns.range(of: "-->", range: NSRange(location: position, length: ns.length - position))
                        .nilIfNotFound else { position = ns.length; break }
                    position = NSMaxRange(end)
                    inComment = false
                } else if let start = find("<!--", from: position) {
                    kept += ns.substring(with: NSRange(location: position, length: start.location - position))
                    position = NSMaxRange(start)
                    inComment = true
                } else {
                    kept += ns.substring(from: position)
                    position = ns.length
                }
            }
            // A line that was only a comment goes, rather than leaving a blank that splits a paragraph.
            if kept.trimmingCharacters(in: .whitespaces).isEmpty, kept != line { continue }
            out.append(kept)
        }
        return out
    }

    /// Footnote references, emoji and embeds in text outside code.
    private static func inline(_ text: String, footnoteTexts: [String: String],
                               footnotes: inout [String], numbers: inout [String: Int]) -> String {
        var text = text
        let ns = text as NSString
        var result = "", start = 0
        for m in footnoteRef.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let number: Int
            if let id = group(m, 1, in: text) {
                guard let definition = footnoteTexts[id] else { continue }   // undefined: leave as typed
                if let n = numbers[id] {
                    number = n
                } else {
                    footnotes.append(definition)
                    number = footnotes.count
                    numbers[id] = number
                }
            } else {
                footnotes.append(group(m, 2, in: text)!)
                number = footnotes.count
            }
            result += ns.substring(with: NSRange(location: start, length: m.range.location - start))
            result += "\(footnoteReference.0)\(number)\(footnoteReference.1)"
            start = NSMaxRange(m.range)
        }
        text = result + ns.substring(from: start)

        // HackMD's image size, `![alt](url =200x100)`, and an image inside a link, `[![alt](url)](link)`.
        text = replace(sizedImage, in: text) { m, s in
            "\(group(m, 1, in: s)!)\(group(m, 2, in: s)!)#\(imageOptionPrefix)size=\(group(m, 3, in: s)!)x\(group(m, 4, in: s)!))"
        }
        text = replace(linkedImage, in: text) { m, s in
            let url = group(m, 2, in: s)!
            let link = group(m, 3, in: s)!.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            return "\(group(m, 1, in: s)!)\(url)\(url.contains("#\(imageOptionPrefix)") ? "&" : "#")\(imageOptionPrefix)link=\(link))"
        }
        text = replace(emojiCode, in: text) { m, s in emoji[group(m, 1, in: s)!] }
        text = replace(embed, in: text) { m, s in
            let kind = group(m, 1, in: s)!.lowercased(), id = group(m, 2, in: s)!
            guard let (name, url) = embedLink(kind, id) else { return nil }
            return "[▶ \(name)：\(id)](\(url))"
        }
        return text
    }

    private static func replace(_ regex: NSRegularExpression, in text: String,
                                _ with: (NSTextCheckingResult, String) -> String?) -> String {
        let ns = text as NSString
        var result = "", start = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let replacement = with(m, text) else { continue }
            result += ns.substring(with: NSRange(location: start, length: m.range.location - start)) + replacement
            start = NSMaxRange(m.range)
        }
        return result + ns.substring(from: start)
    }

    /// The preview can't play embedded media, so embeds link to where they live.
    private static func embedLink(_ kind: String, _ id: String) -> (String, String)? {
        switch kind {
        case "youtube": return ("YouTube", "https://www.youtube.com/watch?v=\(id)")
        case "vimeo": return ("Vimeo", "https://vimeo.com/\(id)")
        case "gist": return ("Gist", "https://gist.github.com/\(id)")
        case "slideshare": return ("SlideShare", "https://www.slideshare.net/\(id)")
        case "speakerdeck": return ("Speaker Deck", "https://speakerdeck.com/\(id)")
        case "pdf": return ("PDF", id)
        case "figma": return ("Figma", id)
        default: return nil
        }
    }

    // MARK: - Rendering

    /// Colors for the boxes: a tinted background and a bar down the left.
    static func styleContainer(_ box: NSTextBlock, kind: String) {
        let color: NSColor
        switch kind {
        case "success": color = .systemGreen
        case "warning": color = .systemOrange
        case "danger": color = .systemRed
        default: color = .systemBlue
        }
        box.backgroundColor = color.withAlphaComponent(0.12)
        box.setWidth(4, type: .absoluteValueType, for: .border, edge: .minX)
        box.setBorderColor(color, for: .minX)
        box.setWidth(10, type: .absoluteValueType, for: .padding)
        box.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
    }

    /// An aligned HTML block (`<div align="center">`) is an invisible box.
    static func styleAlignment(_ box: NSTextBlock) {
        box.setWidth(0, type: .absoluteValueType, for: .border, edge: .minX)
        box.setWidth(0, type: .absoluteValueType, for: .padding)
    }

    /// A spoiler's box has no bar; its content sits a little in from its title.
    static func styleSpoiler(_ box: NSTextBlock) {
        box.setWidth(0, type: .absoluteValueType, for: .border, edge: .minX)
        box.setWidth(2, type: .absoluteValueType, for: .padding, edge: .minX)
    }

    /// Footnote numbers become superscript links to the footnotes, and each footnote gets its anchor.
    static func applyFootnotes(in text: NSMutableAttributedString, fontSize: CGFloat) {
        for (open, close, isReference) in [(footnoteReference.0, footnoteReference.1, true),
                                           (footnoteAnchor.0, footnoteAnchor.1, false)] {
            let regex = try! NSRegularExpression(pattern: "\(open)(\\d+)\(close)")
            for m in regex.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reversed() {
                let number = (text.string as NSString).substring(with: m.range(at: 1))
                if isReference {
                    var attrs = text.attributes(at: m.range.location, effectiveRange: nil)
                    attrs[.font] = NSFont.systemFont(ofSize: fontSize * 0.75)
                    attrs[.baselineOffset] = fontSize * 0.35
                    attrs[.link] = URL(string: "\(anchorScheme)://footnote-\(number)")!
                    attrs[.foregroundColor] = NSColor.linkColor
                    text.replaceCharacters(in: m.range, with: NSAttributedString(string: "[\(number)]", attributes: attrs))
                } else {
                    text.deleteCharacters(in: m.range)
                    if m.range.location < text.length {
                        text.addAttribute(anchor, value: "footnote-\(number)", range: NSRange(location: m.range.location, length: 1))
                    }
                }
            }
        }
    }

    /// Abbreviations get a dotted underline, and their meaning as a tooltip.
    static func applyAbbreviations(_ abbreviations: [(term: String, title: String)], in text: NSMutableAttributedString) {
        for (term, title) in abbreviations {
            let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![\p{L}\p{N}_])"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in regex.matches(in: text.string, range: NSRange(location: 0, length: text.length)) {
                let attrs = text.attributes(at: m.range.location, effectiveRange: nil)
                guard attrs[MarkdownRenderer.inlineCode] == nil, attrs[MarkdownRenderer.codeBlock] == nil,
                      attrs[.link] == nil else { continue }
                text.addAttributes([
                    .toolTip: title,
                    .underlineStyle: NSUnderlineStyle.single.union(.patternDot).rawValue,
                    .underlineColor: NSColor.secondaryLabelColor,
                ], range: m.range)
            }
        }
    }

    // MARK: - Emoji

    /// The GitHub shortcodes people use most; others stay as typed.
    static let emoji: [String: String] = [
        "smile": "😄", "smiley": "😃", "grinning": "😀", "blush": "😊", "relaxed": "☺️", "wink": "😉",
        "heart_eyes": "😍", "kissing_heart": "😘", "laughing": "😆", "satisfied": "😆", "joy": "😂",
        "rofl": "🤣", "sweat_smile": "😅", "slightly_smiling_face": "🙂", "upside_down_face": "🙃",
        "innocent": "😇", "yum": "😋", "sunglasses": "😎", "nerd_face": "🤓", "thinking": "🤔",
        "neutral_face": "😐", "expressionless": "😑", "unamused": "😒", "roll_eyes": "🙄",
        "smirk": "😏", "grimacing": "😬", "relieved": "😌", "pensive": "😔", "sleepy": "😪",
        "sleeping": "😴", "mask": "😷", "dizzy_face": "😵", "exploding_head": "🤯", "cowboy_hat_face": "🤠",
        "partying_face": "🥳", "confused": "😕", "worried": "😟", "frowning": "😦", "open_mouth": "😮",
        "astonished": "😲", "flushed": "😳", "pleading_face": "🥺", "fearful": "😨", "cold_sweat": "😰",
        "cry": "😢", "sob": "😭", "scream": "😱", "confounded": "😖", "persevere": "😣",
        "disappointed": "😞", "sweat": "😓", "weary": "😩", "tired_face": "😫", "triumph": "😤",
        "rage": "😡", "angry": "😠", "smiling_imp": "😈", "skull": "💀", "poop": "💩", "hankey": "💩",
        "clown_face": "🤡", "ghost": "👻", "alien": "👽", "robot": "🤖", "smiley_cat": "😺",
        "see_no_evil": "🙈", "hear_no_evil": "🙉", "speak_no_evil": "🙊",
        "heart": "❤️", "orange_heart": "🧡", "yellow_heart": "💛", "green_heart": "💚", "blue_heart": "💙",
        "purple_heart": "💜", "black_heart": "🖤", "broken_heart": "💔", "sparkling_heart": "💖",
        "two_hearts": "💕", "100": "💯", "anger": "💢", "boom": "💥", "collision": "💥", "dizzy": "💫",
        "sweat_drops": "💦", "zzz": "💤", "wave": "👋", "raised_hand": "✋", "hand": "✋", "ok_hand": "👌",
        "v": "✌️", "crossed_fingers": "🤞", "point_left": "👈", "point_right": "👉", "point_up": "☝️",
        "point_down": "👇", "+1": "👍", "thumbsup": "👍", "-1": "👎", "thumbsdown": "👎", "fist": "✊",
        "punch": "👊", "clap": "👏", "raised_hands": "🙌", "open_hands": "👐", "pray": "🙏",
        "handshake": "🤝", "muscle": "💪", "writing_hand": "✍️", "eyes": "👀", "eye": "👁️", "brain": "🧠",
        "baby": "👶", "boy": "👦", "girl": "👧", "man": "👨", "woman": "👩", "older_man": "👴",
        "older_woman": "👵", "cat": "🐱", "dog": "🐶", "mouse": "🐭", "rabbit": "🐰", "fox_face": "🦊",
        "bear": "🐻", "panda_face": "🐼", "koala": "🐨", "tiger": "🐯", "lion": "🦁", "cow": "🐮",
        "pig": "🐷", "frog": "🐸", "monkey_face": "🐵", "chicken": "🐔", "penguin": "🐧", "bird": "🐦",
        "unicorn": "🦄", "bee": "🐝", "bug": "🐛", "butterfly": "🦋", "snail": "🐌", "turtle": "🐢",
        "snake": "🐍", "octopus": "🐙", "fish": "🐟", "whale": "🐳", "dolphin": "🐬",
        "rose": "🌹", "sunflower": "🌻", "cherry_blossom": "🌸", "tulip": "🌷", "seedling": "🌱",
        "evergreen_tree": "🌲", "deciduous_tree": "🌳", "cactus": "🌵", "four_leaf_clover": "🍀",
        "maple_leaf": "🍁", "fallen_leaf": "🍂", "mushroom": "🍄", "earth_asia": "🌏",
        "sunny": "☀️", "cloud": "☁️", "umbrella": "☔", "snowflake": "❄️", "snowman": "⛄", "zap": "⚡",
        "fire": "🔥", "droplet": "💧", "ocean": "🌊", "rainbow": "🌈", "star": "⭐", "star2": "🌟",
        "sparkles": "✨", "crescent_moon": "🌙", "full_moon": "🌕", "sun_with_face": "🌞",
        "apple": "🍎", "green_apple": "🍏", "banana": "🍌", "grapes": "🍇", "watermelon": "🍉",
        "strawberry": "🍓", "peach": "🍑", "cherries": "🍒", "lemon": "🍋", "tomato": "🍅", "avocado": "🥑",
        "corn": "🌽", "hot_pepper": "🌶️", "bread": "🍞", "cheese": "🧀", "egg": "🥚", "bacon": "🥓",
        "hamburger": "🍔", "fries": "🍟", "pizza": "🍕", "hotdog": "🌭", "taco": "🌮", "ramen": "🍜",
        "spaghetti": "🍝", "sushi": "🍣", "rice": "🍚", "bento": "🍱", "dumpling": "🥟", "icecream": "🍦",
        "cake": "🍰", "birthday": "🎂", "cookie": "🍪", "chocolate_bar": "🍫", "candy": "🍬",
        "coffee": "☕", "tea": "🍵", "beer": "🍺", "beers": "🍻", "wine_glass": "🍷", "cocktail": "🍸",
        "tada": "🎉", "confetti_ball": "🎊", "gift": "🎁", "balloon": "🎈", "christmas_tree": "🎄",
        "jack_o_lantern": "🎃", "trophy": "🏆", "medal_sports": "🏅", "1st_place_medal": "🥇",
        "soccer": "⚽", "basketball": "🏀", "baseball": "⚾", "tennis": "🎾", "football": "🏈",
        "video_game": "🎮", "dart": "🎯", "game_die": "🎲", "art": "🎨", "musical_note": "🎵",
        "notes": "🎶", "microphone": "🎤", "headphones": "🎧", "guitar": "🎸", "movie_camera": "🎥",
        "camera": "📷", "tv": "📺", "computer": "💻", "keyboard": "⌨️", "iphone": "📱", "phone": "☎️",
        "battery": "🔋", "electric_plug": "🔌", "bulb": "💡", "flashlight": "🔦", "wrench": "🔧",
        "hammer": "🔨", "gear": "⚙️", "link": "🔗", "lock": "🔒", "unlock": "🔓", "key": "🔑",
        "bell": "🔔", "mag": "🔍", "book": "📖", "books": "📚", "notebook": "📓", "memo": "📝",
        "pencil": "📝", "pencil2": "✏️", "pen": "🖊️", "paperclip": "📎", "pushpin": "📌",
        "round_pushpin": "📍", "scissors": "✂️", "file_folder": "📁", "open_file_folder": "📂",
        "page_facing_up": "📄", "calendar": "📆", "date": "📅", "clipboard": "📋", "chart_with_upwards_trend": "📈",
        "chart_with_downwards_trend": "📉", "bar_chart": "📊", "email": "📧", "envelope": "✉️",
        "inbox_tray": "📥", "outbox_tray": "📤", "package": "📦", "moneybag": "💰", "dollar": "💵",
        "credit_card": "💳", "gem": "💎", "hourglass": "⌛", "watch": "⌚", "alarm_clock": "⏰",
        "stopwatch": "⏱️", "house": "🏠", "office": "🏢", "school": "🏫", "hospital": "🏥",
        "car": "🚗", "taxi": "🚕", "bus": "🚌", "train": "🚆", "bike": "🚲", "airplane": "✈️",
        "rocket": "🚀", "ship": "🚢", "anchor": "⚓", "construction": "🚧", "rotating_light": "🚨",
        "warning": "⚠️", "no_entry": "⛔", "no_entry_sign": "🚫", "x": "❌", "o": "⭕",
        "heavy_check_mark": "✔️", "white_check_mark": "✅", "ballot_box_with_check": "☑️",
        "heavy_multiplication_x": "✖️", "heavy_plus_sign": "➕", "heavy_minus_sign": "➖",
        "question": "❓", "grey_question": "❔", "exclamation": "❗", "heavy_exclamation_mark": "❗",
        "grey_exclamation": "❕", "bangbang": "‼️", "interrobang": "⁉️", "information_source": "ℹ️",
        "arrow_up": "⬆️", "arrow_down": "⬇️", "arrow_left": "⬅️", "arrow_right": "➡️",
        "arrows_counterclockwise": "🔄", "back": "🔙", "new": "🆕", "free": "🆓", "up": "🆙",
        "cool": "🆒", "ok": "🆗", "sos": "🆘", "red_circle": "🔴", "large_blue_circle": "🔵",
        "green_circle": "🟢", "yellow_circle": "🟡", "white_circle": "⚪", "black_circle": "⚫",
        "copyright": "©️", "registered": "®️", "tm": "™️", "recycle": "♻️", "infinity": "♾️",
        "checkered_flag": "🏁", "triangular_flag_on_post": "🚩", "crown": "👑", "ring": "💍",
        "lipstick": "💄", "eyeglasses": "👓", "necktie": "👔", "shirt": "👕", "jeans": "👖",
        "dress": "👗", "handbag": "👜", "school_satchel": "🎒", "mortar_board": "🎓", "tophat": "🎩",
    ]
}

private extension NSRange {
    var nilIfNotFound: NSRange? { location == NSNotFound ? nil : self }
}
