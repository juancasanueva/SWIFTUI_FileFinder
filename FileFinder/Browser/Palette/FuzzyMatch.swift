import Foundation

/// Scores how well a typed query matches a title, like the command palettes in code editors.
nonisolated enum FuzzyMatch {
    /// `nil` when some word of the query doesn't match; otherwise higher is better.
    /// Each word must appear in order, ignoring case: as one run of letters, or scattered.
    static func score(_ query: String, _ text: String) -> Int? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        let letters = Array(text.lowercased())
        var total = 0
        for word in words {
            guard let wordScore = score(Array(word), in: letters) else { return nil }
            total += wordScore
        }
        return total
    }

    private static func score(_ word: [Character], in text: [Character]) -> Int? {
        if let start = range(of: word, in: text) {
            // One run of letters: best at the very start, then at the start of a word.
            var score = 100 + word.count * 10 - start
            if start == 0 { score += 60 } else if isWordStart(start, in: text) { score += 40 }
            if word.count == text.count { score += 40 }
            return score
        }
        // Scattered letters, taken left to right; a letter at the start of a word counts more.
        var score = 0
        var position = 0
        var previous: Int?
        for character in word {
            guard let found = nextMatch(of: character, in: text, from: position) else { return nil }
            score += 10
            if isWordStart(found, in: text) { score += 15 }
            if let previous, found == previous + 1 { score += 10 }
            score -= min(found - position, 10)
            previous = found
            position = found + 1
        }
        return score
    }

    /// The next `character` at or after `start`, preferring one that starts a word.
    private static func nextMatch(of character: Character, in text: [Character], from start: Int) -> Int? {
        let matches = (start..<text.count).filter { text[$0] == character }
        guard let first = matches.first else { return nil }
        return matches.first { isWordStart($0, in: text) } ?? first
    }

    private static func range(of word: [Character], in text: [Character]) -> Int? {
        guard word.count <= text.count else { return nil }
        return (0...(text.count - word.count)).first { start in
            text[start..<(start + word.count)].elementsEqual(word)
        }
    }

    private static func isWordStart(_ index: Int, in text: [Character]) -> Bool {
        index == 0 || !(text[index - 1].isLetter || text[index - 1].isNumber)
    }
}
