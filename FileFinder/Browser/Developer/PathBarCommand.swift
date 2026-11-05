import Foundation

/// Shell-style commands typed in the path bar (⌘L): `code .`, `cursor .`, `xed .`, `zed`,
/// `warp`, `terminal`, optionally followed by "." or a folder path.
nonisolated struct PathBarCommand: Equatable {
    enum Target: Equatable, Sendable {
        /// A `DeveloperApp.id`.
        case app(String)
        /// The window's Ghostty terminal panel.
        case terminalPanel
    }

    let target: Target
    let folder: URL

    static let words: [String: Target] = [
        "code": .app("vscode"),
        "cursor": .app("cursor"),
        "xed": .app("xcode"),
        "zed": .app("zed"),
        "warp": .app("warp"),
        "terminal": .terminalPanel,
    ]

    /// The command in `text`, with the folder it names (`base` for none or "."), or `nil` when
    /// the text isn't a command or its folder doesn't exist.
    static func parse(_ text: String, relativeTo base: URL) -> PathBarCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = trimmed.prefix { !$0.isWhitespace }
        guard let target = words[word.lowercased()] else { return nil }
        let argument = trimmed.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
        if argument.isEmpty || argument == "." { return PathBarCommand(target: target, folder: base.canonical) }
        guard let folder = PathInput.resolve(argument, relativeTo: base) else { return nil }
        return PathBarCommand(target: target, folder: folder.canonical)
    }
}
