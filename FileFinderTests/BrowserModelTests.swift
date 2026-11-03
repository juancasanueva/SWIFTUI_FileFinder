import AppKit
import Foundation
import Testing
@testable import FileFinder

@MainActor
@Suite("Browser model")
struct BrowserModelTests {
    let dir: TemporaryDirectory
    let defaults: UserDefaults
    let undoManager = UndoManager()

    init() throws {
        dir = try TemporaryDirectory()
        defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        undoManager.groupsByEvent = false
    }

    private func makeModel(start: URL? = nil) -> BrowserModel {
        let actions = FileActions(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))))
        actions.undoManager = undoManager
        return BrowserModel(start: start ?? dir.url, actions: actions, defaults: defaults)
    }

    // MARK: - History

    @Test("Back and forward walk the navigation history")
    func history() throws {
        let a = try dir.folder("a")
        let b = try dir.folder("b")
        let model = makeModel()

        model.navigate(to: a)
        model.navigate(to: b)
        model.goBack()
        #expect(model.currentFolder == a.canonical)
        #expect(model.canGoForward)

        model.goForward()
        #expect(model.currentFolder == b.canonical)
        #expect(!model.canGoForward)

        model.goBack()
        model.navigate(to: dir.url.appending(path: "b"))
        #expect(!model.canGoForward)
    }

    @Test("Going up selects the folder you came from")
    func goUpSelectsChild() throws {
        let child = try dir.folder("child")
        let model = makeModel(start: child)

        model.goUp()

        #expect(model.currentFolder == dir.url.canonical)
        #expect(model.selection == [child.canonical])
    }

    // MARK: - Listing

    @Test("Reload lists folders first, and sorting by size reorders")
    func reloadAndSort() async throws {
        try dir.file("big.bin", bytes: 300)
        try dir.file("small.bin", bytes: 10)
        try dir.folder("zFolder")
        let model = makeModel()

        await model.reload()
        #expect(model.items.map(\.name) == ["zFolder", "big.bin", "small.bin"])

        model.sortOrder = [KeyPathComparator(\.sortSize, order: .reverse)]
        #expect(model.items.map(\.name) == ["big.bin", "small.bin", "zFolder"])
    }

    @Test("Selection drops items that no longer exist after a reload")
    func selectionIsPruned() async throws {
        let keep = try dir.file("keep.txt")
        let gone = try dir.file("gone.txt")
        let model = makeModel()
        await model.reload()
        model.selection = [keep.canonical, gone.canonical]

        try FileManager.default.removeItem(at: gone)
        await model.reload()

        #expect(model.selection == [keep.canonical])
    }

    @Test("A missing folder fails without suggesting Full Disk Access")
    func missingFolderFailure() async throws {
        let model = makeModel(start: dir.url.appending(path: "missing"))

        await model.reload()

        let failure = try #require(model.loadFailure)
        #expect(!failure.needsFullDiskAccess)
        #expect(model.items.isEmpty)
    }

    @Test("An unreadable folder fails and suggests Full Disk Access")
    func permissionFailure() async throws {
        let locked = try dir.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let model = makeModel(start: locked)

        await model.reload()

        #expect(model.loadFailure?.needsFullDiskAccess == true)
    }

    @Test("The default start folder falls back to home when Downloads is missing")
    func defaultStartFolder() throws {
        #expect(BrowserModel.defaultStartFolder(home: dir.url) == dir.url)
        let downloads = try dir.folder("Downloads")
        #expect(BrowserModel.defaultStartFolder(home: dir.url).path == downloads.path)
    }

    // MARK: - Folder sizes

    @Test("Folder sizes are measured and re-measured after the folder's contents change")
    func folderStatsRefresh() async throws {
        let folder = try dir.folder("Photos")
        try dir.file("Photos/a.jpg", bytes: 100)
        let model = makeModel()
        await model.reload()
        await model.measureFolders()
        #expect(model.folderStats[folder.canonical] == FolderStats(totalBytes: 100, itemCount: 1))

        try dir.file("Photos/b.jpg", bytes: 50)
        await model.reload()
        #expect(model.folderStats[folder.canonical] == nil)

        await model.measureFolders()
        #expect(model.folderStats[folder.canonical] == FolderStats(totalBytes: 150, itemCount: 2))
    }

    @Test("A folder that can't be measured shows a placeholder instead of calculating forever")
    func unmeasurableFolder() async throws {
        let locked = try dir.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let model = makeModel()

        await model.reload()
        await model.measureFolders()

        let item = try #require(model.items.first { $0.name == "locked" })
        #expect(model.cardSubtitle(for: item) == "--")
    }

    // MARK: - Opening

    @Test("Opening several folders navigates into the first one only")
    func openSeveralFolders() async throws {
        let first = try dir.folder("a")
        let second = try dir.folder("b")
        let model = makeModel()
        await model.reload()

        model.open([first.canonical, second.canonical])

        #expect(model.currentFolder == first.canonical)
        model.goBack()
        #expect(model.currentFolder == dir.url.canonical)
        #expect(!model.canGoBack)
    }

    // MARK: - File operations

    @Test("Pasting selects the pasted items")
    func pasteSelects() async throws {
        let source = try dir.file("from/x.txt")
        let target = try dir.folder("to")
        let model = makeModel(start: target)
        model.actions.copyToClipboard([source])

        await model.paste()

        #expect(model.selection == [target.appending(path: "x.txt").canonical])
        #expect(model.items.map(\.name) == ["x.txt"])
    }

    @Test("Trashing the selection removes it from the listing")
    func trashSelection() async throws {
        let file = try dir.file("old.log")
        let model = makeModel()
        await model.reload()
        model.selection = [file.canonical]

        await model.trashSelection()

        #expect(model.items.isEmpty)
        #expect(model.selection.isEmpty)
    }

    @Test("Background undo failures surface as an alert")
    func undoFailureAlerts() async throws {
        let file = try dir.file("old.log")
        let model = makeModel()
        await model.reload()
        model.selection = [file.canonical]
        await model.trashSelection()
        try dir.file("old.log")

        undoManager.undo()
        await model.actions.waitForPendingWork()

        #expect(model.alertMessage != nil)
    }

    @Test("Preferences persist to the injected defaults")
    func preferencesPersist() {
        let model = makeModel()
        model.showHidden = true
        model.viewMode = .cards
        model.iconSize = .large

        let reloaded = makeModel()
        #expect(reloaded.showHidden)
        #expect(reloaded.viewMode == .cards)
        #expect(reloaded.iconSize == .large)
    }
}
