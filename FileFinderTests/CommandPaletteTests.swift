import AppKit
import Foundation
import Testing
@testable import FileFinder

/// Returns canned results and remembers what it was asked.
final class FakeFileSearch: FileSearching {
    var results: [PaletteFile] = []
    private(set) var queries: [String] = []

    func search(_ query: String) async -> [PaletteFile] {
        queries.append(query)
        return results
    }
}

@Suite("Fuzzy matching")
struct FuzzyMatchTests {
    @Test("Letters must appear in order, ignoring case")
    func subsequence() {
        #expect(FuzzyMatch.score("NEW", "New Folder") != nil)
        #expect(FuzzyMatch.score("xyz", "New Folder") == nil)
        #expect(FuzzyMatch.score("fn", "New Folder") == nil)
    }

    @Test("Initials match the start of each word")
    func initials() {
        #expect(FuzzyMatch.score("nf", "New Folder") != nil)
    }

    @Test("A match at the start beats letters scattered through the text")
    func prefixWins() throws {
        let prefix = try #require(FuzzyMatch.score("doc", "Documents"))
        let scattered = try #require(FuzzyMatch.score("doc", "Download Center"))
        #expect(prefix > scattered)
    }

    @Test("Every word of the query has to match")
    func words() {
        #expect(FuzzyMatch.score("op term", "Open in Terminal") != nil)
        #expect(FuzzyMatch.score("op zzz", "Open in Terminal") == nil)
    }

    @Test("An empty query matches everything with no score")
    func emptyQuery() {
        #expect(FuzzyMatch.score("  ", "Anything") == 0)
    }
}

@Suite("Spotlight search")
struct SpotlightPredicateTests {
    @Test("One word is a plain name match, since NSMetadataQuery throws on an AND of one")
    func oneWord() throws {
        let predicate = try #require(SpotlightFileSearch.predicate(for: "report"))
        #expect(!(predicate is NSCompoundPredicate))
        #expect(predicate.predicateFormat == #"kMDItemFSName LIKE[cd] "*report*""#)
    }

    @Test("Every word must match, and typed wildcards match themselves")
    func words() throws {
        let predicate = try #require(SpotlightFileSearch.predicate(for: "q3 *draft?") as? NSCompoundPredicate)
        #expect(predicate.compoundPredicateType == .and)
        #expect(predicate.subpredicates.count == 2)
        #expect(SpotlightFileSearch.predicate(for: "   ") == nil)
        let draft = try #require(predicate.subpredicates.last as? NSComparisonPredicate)
        #expect(draft.rightExpression.constantValue as? String == #"*\*draft\?*"#)
    }
}

@MainActor
@Suite("Palette history")
struct PaletteHistoryTests {
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
    }

    @Test("Picked items get a boost that grows with use, newest first, and survive a relaunch")
    func recordAndBoost() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let history = PaletteHistory(defaults: defaults, now: { clock })
        #expect(history.boost(for: "cmd:a") == 0)

        history.record("cmd:a")
        let once = history.boost(for: "cmd:a")
        #expect(once > 0)
        history.record("cmd:a")
        #expect(history.boost(for: "cmd:a") > once)

        clock += 60
        history.record("cmd:b")
        #expect(history.recentKeys == ["cmd:b", "cmd:a"])

        let reopened = PaletteHistory(defaults: defaults, now: { clock })
        #expect(reopened.recentKeys == ["cmd:b", "cmd:a"])
        #expect(reopened.boost(for: "cmd:a") == history.boost(for: "cmd:a"))
    }
}

@MainActor
@Suite("Command palette")
struct CommandPaletteTests {
    let dir: TemporaryDirectory
    let defaults: UserDefaults
    let search = FakeFileSearch()

    init() throws {
        dir = try TemporaryDirectory()
        defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
    }

    private func makePalette(
        commands: [PaletteCommand],
        history: PaletteHistory? = nil,
        openFile: @escaping (PaletteFile, Bool) -> Void = { _, _ in }
    ) -> CommandPaletteModel {
        CommandPaletteModel(
            commands: commands, search: search, history: history ?? PaletteHistory(defaults: defaults),
            debounce: .zero, openFile: openFile)
    }

    private func command(_ title: String, run: @escaping () -> Void = {}) -> PaletteCommand {
        PaletteCommand(id: title, title: title, shortcut: nil, run: run)
    }

    @Test("Typing filters the commands, best match first")
    func filtersCommands() {
        let palette = makePalette(commands: [command("Move to Trash"), command("New Folder"), command("Swap Panes")])
        palette.query = "nf"
        #expect(palette.results.map(\.title) == ["New Folder"])

        palette.query = "pa"
        #expect(palette.results.map(\.title) == ["Swap Panes"])
    }

    @Test("Of two equal matches, the one picked before comes first")
    func historyRanking() {
        let history = PaletteHistory(defaults: defaults)
        let palette = makePalette(commands: [command("Alpha Beta"), command("Alpha Gamma")], history: history)
        palette.query = "alpha"
        #expect(palette.results.map(\.title) == ["Alpha Beta", "Alpha Gamma"])

        palette.highlight(1)
        palette.activate()

        let again = makePalette(commands: [command("Alpha Beta"), command("Alpha Gamma")], history: history)
        again.query = "alpha"
        #expect(again.results.map(\.title) == ["Alpha Gamma", "Alpha Beta"])
    }

    @Test("An empty query lists recent picks first, leaving out files that are gone, then every other command in menu order")
    func recents() throws {
        let kept = try dir.file("kept.txt")
        let gone = dir.url.appending(path: "gone.txt")
        let history = PaletteHistory(defaults: defaults)
        history.record(PaletteItem.file(PaletteFile(url: gone, isDirectory: false)).id)
        history.record("cmd:New Folder")
        history.record(PaletteItem.file(PaletteFile(url: kept, isDirectory: false)).id)

        let palette = makePalette(
            commands: [command("Swap Panes"), command("New Folder"), command("Copy")], history: history)
        #expect(palette.results.map(\.title) == ["kept.txt", "New Folder", "Swap Panes", "Copy"])
    }

    @Test("Two or more letters search files after the commands; one letter doesn't")
    func searchesFiles() async throws {
        let folder = try dir.folder("Projects")
        search.results = [PaletteFile(url: folder, isDirectory: true)]
        let palette = makePalette(commands: [command("Open in Terminal"), command("Project Settings")])

        palette.query = "p"
        await palette.waitForSearch()
        #expect(search.queries.isEmpty)

        palette.query = "proj"
        await palette.waitForSearch()
        #expect(search.queries == ["proj"])
        #expect(palette.results.map(\.title) == ["Project Settings", "Projects"])
    }

    @Test("The highlighted file stays highlighted when a newer search lands, and old files that no longer match go")
    func keepsHighlightAcrossSearches() async {
        func file(_ name: String) -> PaletteFile { PaletteFile(url: dir.url.appending(path: name), isDirectory: false) }
        search.results = [file("rep_a.txt"), file("rep_b.txt"), file("rex.txt")]
        let palette = makePalette(commands: [])
        palette.query = "re"
        await palette.waitForSearch()

        search.results = [file("rep_0.txt"), file("rep_00.txt"), file("rep_b.txt")]
        palette.query = "rep"
        #expect(palette.results.map(\.title) == ["rep_a.txt", "rep_b.txt"])
        palette.highlight(1)
        await palette.waitForSearch()
        #expect(palette.results.map(\.title) == ["rep_0.txt", "rep_00.txt", "rep_b.txt"])
        #expect(palette.highlightedItem?.title == "rep_b.txt")
    }

    @Test("Arrow keys stay inside the list, and a new query goes back to the top")
    func highlightMoves() {
        let palette = makePalette(commands: [command("Alpha"), command("Also"), command("Beta")])
        palette.query = "al"
        #expect(palette.highlightedIndex == 0)
        palette.moveHighlight(by: -1)
        #expect(palette.highlightedIndex == 0)
        palette.moveHighlight(by: 1)
        palette.moveHighlight(by: 1)
        #expect(palette.highlightedIndex == 1)

        palette.query = "a"
        #expect(palette.highlightedIndex == 0)
    }

    @Test("Return runs a command, opens a file, or with ⌘ reveals it; each pick is remembered")
    func activates() async throws {
        var ran = false
        var opened: [(PaletteFile, Bool)] = []
        let file = PaletteFile(url: try dir.file("Report.pdf"), isDirectory: false)
        search.results = [file]
        let history = PaletteHistory(defaults: defaults)
        let palette = makePalette(commands: [command("Rename") { ran = true }], history: history) { opened.append(($0, $1)) }

        palette.query = "ren"
        palette.activate()
        #expect(ran)

        palette.query = "report"
        await palette.waitForSearch()
        palette.activate(revealing: true)
        #expect(opened.map(\.0) == [file])
        #expect(opened.map(\.1) == [true])
        #expect(Set(history.recentKeys) == ["cmd:Rename", PaletteItem.file(file).id])
    }
}

@MainActor
@Suite("Command palette in a window")
struct CommandPaletteWindowTests {
    let dir: TemporaryDirectory
    let defaults: UserDefaults
    let search = FakeFileSearch()

    init() throws {
        dir = try TemporaryDirectory()
        defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
    }

    private func makeWindow(workspaces: WorkspaceStore? = nil) -> BrowserWindowModel {
        let actions = FileActions(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))))
        return BrowserWindowModel(
            defaultStart: dir.url, actions: actions, defaults: defaults,
            workspaces: workspaces ?? WorkspaceStore(fileURL: dir.url.appending(path: "store/workspaces.json")),
            fileSearch: search)
    }

    @Test("⌘K opens the palette and again closes it")
    func toggles() {
        let window = makeWindow()
        #expect(!window.isShowingPalette)
        window.togglePalette()
        #expect(window.isShowingPalette)
        window.togglePalette()
        #expect(!window.isShowingPalette)
    }

    @Test("The palette offers only commands that can run now, and never itself; with nothing typed it lists them all")
    func offersEnabledCommands() throws {
        let window = makeWindow()
        window.togglePalette()
        #expect(window.palette?.results.map(\.title) == window.palette?.commands.map(\.title))
        var titles = try #require(window.palette).commands.map(\.title)
        #expect(titles.contains("New Folder"))
        #expect(titles.contains("Split View"))
        #expect(!titles.contains("Swap Panes"))
        #expect(!titles.contains(KeyAction.commandPalette.title))

        window.togglePalette()
        window.toggleSplit()
        window.togglePalette()
        titles = try #require(window.palette).commands.map(\.title)
        #expect(titles.contains("Swap Panes"))
        #expect(titles.contains("Close Split View"))
    }

    @Test("Picking a folder opens it in the active pane and closes the palette; ⌘ reveals it instead")
    func opensFolder() async throws {
        let folder = try dir.folder("Projects/App")
        search.results = [PaletteFile(url: folder, isDirectory: true)]
        let window = makeWindow()

        window.togglePalette()
        try #require(window.palette).query = "app"
        await window.palette?.waitForSearch()
        window.activatePalette()
        #expect(!window.isShowingPalette)
        #expect(window.active.currentFolder == folder.canonical)

        window.togglePalette()
        try #require(window.palette).query = "app"
        await window.palette?.waitForSearch()
        window.activatePalette(revealing: true)
        #expect(window.active.currentFolder == folder.deletingLastPathComponent().canonical)
        #expect(window.active.selection == [folder.canonical])
    }

    @Test("Each workspace is a command that opens it in the active pane")
    func opensWorkspace() async throws {
        let store = WorkspaceStore(fileURL: dir.url.appending(path: "store/workspaces.json"))
        let clients = store.create(named: "Clients")
        let window = makeWindow(workspaces: store)

        window.togglePalette()
        try #require(window.palette).query = "clients"
        #expect(window.palette?.results.map(\.title) == ["Open Workspace \u{201C}Clients\u{201D}"])
        window.activatePalette()
        for _ in 0..<1_000 where window.active.workspaceID != clients.id {
            await Task.yield()
        }
        #expect(window.active.workspaceID == clients.id)
    }

    @Test("The menus keep their rules: Swap needs two panes, Rename one item")
    func menuRules() throws {
        let store = WorkspaceStore(fileURL: dir.url.appending(path: "store/workspaces.json"))
        let window = makeWindow(workspaces: store)
        var runner: KeyActionRunner { KeyActionRunner(browser: window.active, window: window) }
        #expect(runner.canPerform(.newFolder))
        #expect(!runner.canPerform(.swapPanes))
        #expect(!runner.canPerform(.rename))

        window.active.selection = [try dir.file("a.txt")]
        #expect(runner.canPerform(.rename))
        window.active.selection.insert(try dir.file("b.txt"))
        #expect(!runner.canPerform(.rename))

        window.toggleSplit()
        #expect(runner.canPerform(.swapPanes))
        #expect(runner.title(.splitView) == "Close Split View")
    }

    @Test("While the palette is open, menu shortcuts leave the selection alone")
    func menusTreatPaletteAsTyping() throws {
        let window = makeWindow()
        window.active.selection = [try dir.file("a.txt")]
        let runner = KeyActionRunner(browser: window.active, window: window)
        #expect(runner.canPerform(.moveToTrash))

        window.togglePalette()
        #expect(!KeyActionRunner(browser: window.active, window: window).canPerform(.moveToTrash))
        #expect(KeyActionRunner(browser: window.active, window: window).canPerform(.commandPalette))
    }
}
