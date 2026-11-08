import Foundation

/// One block of a Markdown document, as the preview draws it. Inline styling (bold, links,
/// code spans) stays in the text and is drawn by `AttributedString(markdown:)`.
nonisolated enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `marker` is •, a number such as 1., or ☐ / ☑ for a task.
    case listItem(marker: String, text: String, depth: Int)
    case quote(String)
    case code(language: String?, text: String)
    case rule
    case table([[String]])
}

/// Splits Markdown into blocks, line by line. Covers what notes and READMEs use; anything it
/// doesn't know reads as a paragraph.
nonisolated enum MarkdownBlocks {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var index = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))) }
            paragraph = []
            quote = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { index += 1 }

            if let fence = fence(trimmed) {
                flush()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            // Setext headings: a line of = or - under a paragraph line.
            if !paragraph.isEmpty, quote.isEmpty, isRun(of: "=", trimmed) || isRun(of: "-", trimmed) {
                let title = paragraph.removeLast()
                flush()
                blocks.append(.heading(level: trimmed.hasPrefix("=") ? 1 : 2, text: title))
                continue
            }
            if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
                continue
            }
            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { flush() }
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                flush()
                blocks.append(item)
                continue
            }
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flush()
                var rows = [cells(trimmed)]
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index]))
                    index += 1
                }
                index -= 1
                blocks.append(.table(rows))
                continue
            }
            // An indented line right after a list item continues it.
            if paragraph.isEmpty, quote.isEmpty, line.hasPrefix("  "),
               case .listItem(let marker, let itemText, let depth)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(marker: marker, text: itemText + " " + trimmed, depth: depth)
                continue
            }
            if !quote.isEmpty { flush() }
            paragraph.append(trimmed)
        }
        flush()
        return blocks
    }

    private static func fence(_ line: String) -> String? {
        line.hasPrefix("```") ? "```" : line.hasPrefix("~~~") ? "~~~" : nil
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        while title.hasSuffix("#") { title.removeLast() }
        return .heading(level: hashes, text: title.trimmingCharacters(in: .whitespaces))
    }

    private static func isRun(of character: Character, _ line: String) -> Bool {
        !line.isEmpty && line.allSatisfy { $0 == character }
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { $0 != " " }
        return compact.count >= 3 && ["-", "*", "_"].contains { isRun(of: $0, compact) }
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let depth = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        let rest = line.dropFirst(indent.count)
        var marker: String
        var text: Substring
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            marker = "•"
            text = rest.dropFirst(2)
        } else {
            let digits = rest.prefix { $0.isNumber }
            let after = rest.dropFirst(digits.count)
            guard !digits.isEmpty, digits.count <= 9, let dot = after.first, dot == "." || dot == ")",
                  after.dropFirst().first == " " else { return nil }
            marker = digits + "."
            text = after.dropFirst(2)
        }
        if marker == "•", text.hasPrefix("[ ] ") {
            marker = "☐"
            text = text.dropFirst(4)
        } else if marker == "•", text.lowercased().hasPrefix("[x] ") {
            marker = "☑"
            text = text.dropFirst(4)
        }
        return .listItem(marker: marker, text: text.trimmingCharacters(in: .whitespaces), depth: depth)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.contains("-")
            && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
