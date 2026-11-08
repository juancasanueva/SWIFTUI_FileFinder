import Foundation

/// How one family of languages writes keywords, comments and strings. Enough to color a
/// preview; it is not a parser.
nonisolated struct SyntaxLanguage: Equatable, Sendable {
    let name: String
    let keywords: Set<String>
    let lineComments: [String]
    let blockComment: (start: String, end: String)?
    let quotes: Set<Character>
    /// Keywords match whatever the case (SQL).
    var ignoresCase = false
    /// `key:` or `key =` at the start of a line is a key (YAML, TOML, INI).
    var keysAtLineStart = false
    /// A string followed by `:` is a key (JSON).
    var stringKeys = false
    /// `"""` and `'''` strings run across lines (Python).
    var tripleQuotes = false

    static func == (lhs: SyntaxLanguage, rhs: SyntaxLanguage) -> Bool { lhs.name == rhs.name }

    static let plain = SyntaxLanguage(name: "Text", keywords: [], lineComments: [], blockComment: nil, quotes: [])

    static let swift = SyntaxLanguage(
        name: "Swift",
        keywords: ["actor", "any", "as", "async", "await", "break", "case", "catch", "class", "continue", "default",
                   "defer", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func",
                   "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "nonisolated",
                   "open", "operator", "private", "protocol", "public", "repeat", "rethrows", "return", "self",
                   "Self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true",
                   "try", "typealias", "var", "where", "while", "mutating", "override", "final", "lazy", "weak"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""])

    /// C, C++, Objective-C, Java, Kotlin, C#, Go, Rust, JavaScript, TypeScript, Dart, PHP, CSS…
    static let cLike = SyntaxLanguage(
        name: "Code",
        keywords: ["abstract", "async", "await", "bool", "boolean", "break", "case", "catch", "char", "class",
                   "const", "continue", "default", "defer", "delete", "do", "double", "else", "enum", "export",
                   "extends", "false", "final", "finally", "float", "fn", "for", "from", "fun", "func", "function",
                   "go", "if", "impl", "implements", "import", "in", "instanceof", "int", "interface", "let",
                   "long", "match", "mod", "mut", "namespace", "new", "nil", "null", "object", "of", "override",
                   "package", "private", "protected", "pub", "public", "return", "self", "short", "static",
                   "string", "struct", "super", "switch", "this", "throw", "throws", "trait", "true", "try",
                   "type", "typeof", "undefined", "unsigned", "use", "using", "val", "var", "void", "when",
                   "where", "while", "yield", "#include", "#define", "#import", "#if", "#endif"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"])

    static let python = SyntaxLanguage(
        name: "Python",
        keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
                   "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is",
                   "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try",
                   "while", "with", "yield"],
        lineComments: ["#"], blockComment: nil, quotes: ["\"", "'"], tripleQuotes: true)

    static let ruby = SyntaxLanguage(
        name: "Ruby",
        keywords: ["begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "false",
                   "for", "if", "in", "module", "next", "nil", "not", "or", "and", "require", "rescue", "return",
                   "self", "super", "then", "true", "unless", "until", "when", "while", "yield"],
        lineComments: ["#"], blockComment: nil, quotes: ["\"", "'"])

    /// Shell scripts and the many config files that use # comments.
    static let shell = SyntaxLanguage(
        name: "Shell",
        keywords: ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in",
                   "local", "return", "then", "while", "FROM", "RUN", "COPY", "ADD", "CMD", "ENTRYPOINT", "ENV",
                   "WORKDIR", "EXPOSE", "ARG", "LABEL", "USER", "VOLUME"],
        lineComments: ["#"], blockComment: nil, quotes: ["\"", "'"])

    static let sql = SyntaxLanguage(
        name: "SQL",
        keywords: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set",
                   "delete", "create", "table", "drop", "alter", "index", "join", "left", "right", "inner",
                   "outer", "on", "as", "group", "by", "order", "having", "limit", "null", "primary", "key",
                   "foreign", "references", "default", "distinct", "union", "case", "when", "then", "else", "end"],
        lineComments: ["--"], blockComment: ("/*", "*/"), quotes: ["'", "\""], ignoresCase: true)

    static let json = SyntaxLanguage(
        name: "JSON", keywords: ["true", "false", "null"], lineComments: [], blockComment: nil,
        quotes: ["\""], stringKeys: true)

    static let yaml = SyntaxLanguage(
        name: "YAML", keywords: ["true", "false", "null", "yes", "no", "on", "off"], lineComments: ["#"],
        blockComment: nil, quotes: ["\"", "'"], keysAtLineStart: true)

    /// TOML, INI, .properties and .env files.
    static let keyValue = SyntaxLanguage(
        name: "Config", keywords: ["true", "false"], lineComments: ["#", ";"], blockComment: nil,
        quotes: ["\"", "'"], keysAtLineStart: true)

    /// XML, HTML, plists and SVG: only comments and attribute values are colored.
    static let markup = SyntaxLanguage(
        name: "Markup", keywords: [], lineComments: [], blockComment: ("<!--", "-->"), quotes: ["\""])
}

/// A colored stretch of text.
nonisolated struct SyntaxToken: Equatable, Sendable {
    enum Kind: Sendable { case keyword, string, number, comment, key }
    let kind: Kind
    /// In UTF-16 units, as `NSString` counts.
    let range: NSRange
}

nonisolated enum SyntaxHighlighter {
    /// The colored stretches of `text`, in order and never overlapping.
    static func tokens(in text: String, language: SyntaxLanguage) -> [SyntaxToken] {
        guard language != .plain else { return [] }
        let chars = Array(text.utf16)
        let keywords = language.ignoresCase ? Set(language.keywords.map { $0.lowercased() }) : language.keywords
        var tokens: [SyntaxToken] = []
        var index = 0
        var lineStart = 0

        func matches(_ string: String, at position: Int) -> Bool {
            let units = Array(string.utf16)
            guard position + units.count <= chars.count else { return false }
            return chars[position..<(position + units.count)].elementsEqual(units)
        }
        func add(_ kind: SyntaxToken.Kind, _ start: Int, _ end: Int) {
            tokens.append(SyntaxToken(kind: kind, range: NSRange(location: start, length: end - start)))
        }
        func lineEnd(from position: Int) -> Int {
            var end = position
            while end < chars.count, chars[end] != newline { end += 1 }
            return end
        }
        /// Only spaces, tabs and a YAML list dash before `position` on its line.
        func startsLine(_ position: Int) -> Bool {
            chars[lineStart..<position].allSatisfy { $0 == space || $0 == tab || $0 == dash }
        }

        while index < chars.count {
            let char = chars[index]
            if char == newline {
                index += 1
                lineStart = index
                continue
            }
            if let block = language.blockComment, matches(block.start, at: index) {
                var end = index + block.start.utf16.count
                while end < chars.count, !matches(block.end, at: end) { end += 1 }
                end = min(end + block.end.utf16.count, chars.count)
                add(.comment, index, end)
                lineStart = (chars[index..<end].lastIndex(of: newline)).map { $0 + 1 } ?? lineStart
                index = end
                continue
            }
            // A # or ; comment needs a space or the line start before it, so `a#b` and `$#` stay text.
            if let comment = language.lineComments.first(where: { matches($0, at: index) }),
               comment == "//" || comment == "--" || index == lineStart
                || chars[index - 1] == space || chars[index - 1] == tab {
                let end = lineEnd(from: index)
                add(.comment, index, end)
                index = end
                continue
            }
            if let scalar = Unicode.Scalar(char), language.quotes.contains(Character(scalar)) {
                let start = index
                let triple = language.tripleQuotes && index + 2 < chars.count
                    && chars[index + 1] == char && chars[index + 2] == char
                var end = index + (triple ? 3 : 1)
                while end < chars.count {
                    if chars[end] == backslash { end += 2; continue }
                    if triple {
                        if end + 2 < chars.count, chars[end] == char, chars[end + 1] == char, chars[end + 2] == char {
                            end += 3
                            break
                        }
                    } else if chars[end] == char {
                        end += 1
                        break
                    } else if chars[end] == newline && char != backtick {
                        break
                    }
                    end += 1
                }
                end = min(end, chars.count)
                var kind = SyntaxToken.Kind.string
                if language.stringKeys {
                    var next = end
                    while next < chars.count, chars[next] == space || chars[next] == tab { next += 1 }
                    if next < chars.count, chars[next] == colon { kind = .key }
                }
                add(kind, start, end)
                if let lastNewline = chars[start..<end].lastIndex(of: newline) { lineStart = lastNewline + 1 }
                index = end
                continue
            }
            let previousIsWord = index > 0 && isWord(chars[index - 1])
            if isDigit(char), !previousIsWord {
                var end = index + 1
                while end < chars.count, isWord(chars[end]) || chars[end] == dot { end += 1 }
                add(.number, index, end)
                index = end
                continue
            }
            if isWordStart(char), !previousIsWord {
                var end = index + 1
                let keyChars = language.keysAtLineStart
                while end < chars.count, isWord(chars[end]) || (keyChars && (chars[end] == dash || chars[end] == dot)) {
                    end += 1
                }
                let word = String(utf16CodeUnits: Array(chars[index..<end]), count: end - index)
                if language.keysAtLineStart, startsLine(index), isKeyEnd(chars, from: end) {
                    add(.key, index, end)
                } else if keywords.contains(language.ignoresCase ? word.lowercased() : word) {
                    add(.keyword, index, end)
                }
                index = end
                continue
            }
            index += 1
        }
        return tokens
    }

    /// A `:` or `=` after optional spaces.
    private static func isKeyEnd(_ chars: [UInt16], from position: Int) -> Bool {
        var next = position
        while next < chars.count, chars[next] == space || chars[next] == tab { next += 1 }
        return next < chars.count && (chars[next] == colon || chars[next] == equals)
    }

    private static func isDigit(_ char: UInt16) -> Bool { char >= 48 && char <= 57 }
    private static func isLetter(_ char: UInt16) -> Bool { (char >= 65 && char <= 90) || (char >= 97 && char <= 122) }
    private static func isWordStart(_ char: UInt16) -> Bool { isLetter(char) || char == underscore || char == hash }
    private static func isWord(_ char: UInt16) -> Bool { isLetter(char) || isDigit(char) || char == underscore }

    private static let newline: UInt16 = 10, tab: UInt16 = 9, space: UInt16 = 32, dash: UInt16 = 45
    private static let backslash: UInt16 = 92, colon: UInt16 = 58, equals: UInt16 = 61, dot: UInt16 = 46
    private static let underscore: UInt16 = 95, hash: UInt16 = 35, backtick: UInt16 = 96
}

/// Which text preview a file gets, from its name.
nonisolated enum TextPreviewKind: Equatable, Sendable {
    case markdown
    case code(SyntaxLanguage)

    init?(url: URL) {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "mdown", "mkd"].contains(ext) {
            self = .markdown
            return
        }
        let byExtension: [String: SyntaxLanguage] = [
            "swift": .swift,
            "c": .cLike, "h": .cLike, "m": .cLike, "mm": .cLike, "cpp": .cLike, "hpp": .cLike, "cc": .cLike,
            "java": .cLike, "kt": .cLike, "kts": .cLike, "cs": .cLike, "go": .cLike, "rs": .cLike,
            "js": .cLike, "mjs": .cLike, "cjs": .cLike, "jsx": .cLike, "ts": .cLike, "tsx": .cLike,
            "dart": .cLike, "scala": .cLike, "php": .cLike, "css": .cLike, "scss": .cLike, "less": .cLike,
            "gradle": .cLike, "groovy": .cLike, "zig": .cLike,
            "py": .python, "rb": .ruby, "sql": .sql,
            "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell,
            "json": .json, "jsonc": .json, "yml": .yaml, "yaml": .yaml,
            "toml": .keyValue, "ini": .keyValue, "cfg": .keyValue, "conf": .keyValue, "properties": .keyValue,
            "env": .keyValue,
            "xml": .markup, "html": .markup, "htm": .markup, "plist": .markup, "svg": .markup,
            "xcconfig": .keyValue, "entitlements": .markup, "storyboard": .markup,
            "txt": .plain, "log": .plain, "csv": .plain, "tsv": .plain,
        ]
        let byName: [String: SyntaxLanguage] = [
            "dockerfile": .shell, "makefile": .shell, "gemfile": .ruby, "podfile": .ruby, "brewfile": .ruby,
            ".gitignore": .shell, ".gitattributes": .shell, ".dockerignore": .shell, ".zshrc": .shell,
            ".bashrc": .shell, ".profile": .shell, ".zprofile": .shell, ".env": .keyValue,
            ".editorconfig": .keyValue, ".gitconfig": .keyValue, "license": .plain, "readme": .plain,
        ]
        guard let language = byName[name] ?? byExtension[ext] else { return nil }
        self = .code(language)
    }
}
