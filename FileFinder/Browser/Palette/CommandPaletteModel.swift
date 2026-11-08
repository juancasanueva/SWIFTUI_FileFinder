import AppKit

/// A file or folder found by the palette's search.
nonisolated struct PaletteFile: Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
}

/// Finds files and folders whose names match a query.
protocol FileSearching {
    func search(_ query: String) async -> [PaletteFile]
}

/// A command the palette can run, such as a menu action.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    /// The shortcut as the menus show it, such as ⇧⌘N.
    let shortcut: String?
    let run: () -> Void
}

/// One row of the palette.
enum PaletteItem: Identifiable {
    case command(PaletteCommand)
    case file(PaletteFile)

    /// Also the key the history remembers it by.
    var id: String {
        switch self {
        case .command(let command): "cmd:\(command.id)"
        case .file(let file): "file:\(file.url.path)"
        }
    }

    var title: String {
        switch self {
        case .command(let command): command.title
        case .file(let file): file.url.lastPathComponent
        }
    }
}

/// ⌘K: one search box for commands and for files anywhere on the Mac.
/// Commands match as you type; files come from a search once the query has two letters.
/// Items picked before rank higher; an empty query lists the recent picks, then every command.
@Observable
final class CommandPaletteModel {
    /// Commands shown, at most.
    static let commandLimit = 8
    /// Files shown, at most.
    static let fileLimit = 40
    /// Recent picks listed above all the commands when nothing is typed, at most.
    static let recentLimit = 8

    var query = "" {
        didSet { queryChanged() }
    }
    private(set) var results: [PaletteItem] = []
    private(set) var highlightedIndex = 0
    private(set) var isSearching = false

    let commands: [PaletteCommand]
    @ObservationIgnored private let search: any FileSearching
    @ObservationIgnored private let history: PaletteHistory
    @ObservationIgnored private let fileExists: (URL) -> Bool
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let openFile: (PaletteFile, _ revealing: Bool) -> Void
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private var files: [PaletteFile] = []

    init(
        commands: [PaletteCommand],
        search: any FileSearching,
        history: PaletteHistory,
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        debounce: Duration = .milliseconds(150),
        openFile: @escaping (PaletteFile, _ revealing: Bool) -> Void
    ) {
        self.commands = commands
        self.search = search
        self.history = history
        self.fileExists = fileExists
        self.debounce = debounce
        self.openFile = openFile
        rank()
    }

    var highlightedItem: PaletteItem? {
        results.indices.contains(highlightedIndex) ? results[highlightedIndex] : nil
    }

    func moveHighlight(by offset: Int) {
        guard !results.isEmpty else { return }
        highlightedIndex = min(max(highlightedIndex + offset, 0), results.count - 1)
    }

    func highlight(_ index: Int) {
        guard results.indices.contains(index) else { return }
        highlightedIndex = index
    }

    /// Runs the highlighted command or opens the highlighted file; `revealing` (⌘Return)
    /// shows a file in its folder instead. Returns whether there was anything to run.
    @discardableResult
    func activate(revealing: Bool = false) -> Bool {
        guard let item = highlightedItem else { return false }
        searchTask?.cancel()
        history.record(item.id)
        switch item {
        case .command(let command): command.run()
        case .file(let file): openFile(file, revealing)
        }
        return true
    }

    /// Waits for the file search started by the last query change.
    func waitForSearch() async {
        await searchTask?.value
    }

    private func queryChanged() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        if text.count < 2 {
            files = []
            isSearching = false
            searchTask = nil
        } else {
            isSearching = true
            searchTask = Task { [search, debounce] in
                if debounce > .zero {
                    try? await Task.sleep(for: debounce)
                }
                guard !Task.isCancelled else { return }
                let found = await search.search(text)
                guard !Task.isCancelled else { return }
                // Keep the same item highlighted, so Return never opens something else.
                let highlightedID = highlightedItem?.id
                files = found
                isSearching = false
                rank()
                highlightedIndex = highlightedID.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
            }
        }
        rank()
        highlightedIndex = 0
    }

    private func rank() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = recents()
            return
        }
        let matchedCommands = commands
            .compactMap { command -> (PaletteItem, Int)? in
                let item = PaletteItem.command(command)
                return FuzzyMatch.score(text, command.title).map { (item, $0 + history.boost(for: item.id)) }
            }
        // Until a newer search lands, the last one's files stay, minus those that no longer match.
        let rankedFiles = files.compactMap { file -> (PaletteItem, Int)? in
            let item = PaletteItem.file(file)
            return FuzzyMatch.score(text, item.title).map { (item, $0 + history.boost(for: item.id)) }
        }
        results = Self.best(matchedCommands, limit: Self.commandLimit)
            + Self.best(rankedFiles, limit: Self.fileLimit)
    }

    /// With nothing typed: recent picks that can still be used (commands offered now, files
    /// still on disk), then every other command in menu order, so ⌘K doubles as a shortcut list.
    private func recents() -> [PaletteItem] {
        let commandsByKey = Dictionary(commands.map { (PaletteItem.command($0).id, $0) }, uniquingKeysWith: { first, _ in first })
        let recent = history.recentKeys.lazy.compactMap { key -> PaletteItem? in
            if let command = commandsByKey[key] { return .command(command) }
            guard key.hasPrefix("file:") else { return nil }
            let url = URL(filePath: String(key.dropFirst("file:".count)))
            guard self.fileExists(url) else { return nil }
            return .file(PaletteFile(url: url, isDirectory: Self.isFolder(url)))
        }
        let shown = Array(recent.prefix(Self.recentLimit))
        let shownIDs = Set(shown.map(\.id))
        return shown + commands.map(PaletteItem.command).filter { !shownIDs.contains($0.id) }
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && !NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    /// Highest score first; equal scores in title order, so the list doesn't jump around.
    private static func best(_ scored: [(PaletteItem, Int)], limit: Int) -> [PaletteItem] {
        scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending }
            .prefix(limit)
            .map(\.0)
    }
}
