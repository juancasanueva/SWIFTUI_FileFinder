import AppKit
import Foundation
import Testing
@testable import FileFinder

@Suite("Column path")
struct ColumnPathTests {
    let root = URL(filePath: "/Users/me")

    @Test("Columns run from the root down to the current folder")
    func folders() {
        #expect(ColumnPath.folders(root: root, current: URL(filePath: "/Users/me")) == [root])
        #expect(ColumnPath.folders(root: root, current: URL(filePath: "/Users/me/Code/App")).map(\.path)
                == ["/Users/me", "/Users/me/Code", "/Users/me/Code/App"])
    }

    @Test("A folder outside the root starts the columns again; one inside keeps them")
    func newRoot() {
        #expect(ColumnPath.root(keeping: root, current: URL(filePath: "/Users/me/Code")) == root)
        #expect(ColumnPath.root(keeping: root, current: URL(filePath: "/Users")).path == "/Users")
        #expect(ColumnPath.root(keeping: root, current: URL(filePath: "/Users/meow")).path == "/Users/meow")
        #expect(ColumnPath.root(keeping: URL(filePath: "/"), current: URL(filePath: "/tmp")).path == "/")
    }
}

@MainActor
@Suite("Column view")
struct ColumnViewTests {
    let dir: TemporaryDirectory
    let defaults: UserDefaults

    init() throws {
        dir = try TemporaryDirectory()
        defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
    }

    private func makeModel(start: URL? = nil) -> BrowserModel {
        let actions = FileActions(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))))
        return BrowserModel(start: start ?? dir.url, actions: actions, defaults: defaults)
    }

    @Test("Opening folders adds columns; going above the first column starts again from there")
    func columnsFollowNavigation() throws {
        let code = try dir.folder("Code")
        let app = try dir.folder("Code/App")
        let model = makeModel()
        #expect(model.columnFolders == [dir.url.canonical])

        model.navigate(to: code)
        model.navigate(to: app)
        #expect(model.columnFolders == [dir.url.canonical, code.canonical, app.canonical])

        model.navigate(to: code)
        #expect(model.columnFolders == [dir.url.canonical, code.canonical])

        model.navigate(to: dir.url)
        model.goUp()
        #expect(model.columnFolders == [dir.url.deletingLastPathComponent().canonical])
    }

    @Test("→ enters the selected folder and selects its first item; ← goes back with the folder selected")
    func arrowKeys() async throws {
        let code = try dir.folder("Code")
        try dir.file("Code/b.txt")
        try dir.file("Code/a.txt")
        let model = makeModel()
        await model.reload()
        model.selection = [code.canonical]

        #expect(model.enterSelectedFolderSelectingFirst())
        await model.reload()
        #expect(model.currentFolder == code.canonical)
        #expect(model.selection == [code.appending(path: "a.txt").canonical])

        model.goUp()
        #expect(model.currentFolder == dir.url.canonical)
        #expect(model.selection == [code.canonical])
    }

    @Test("→ on a file does nothing")
    func arrowOnFile() async throws {
        let file = try dir.file("a.txt")
        let model = makeModel()
        await model.reload()
        model.selection = [file.canonical]
        #expect(!model.enterSelectedFolderSelectingFirst())
        #expect(model.currentFolder == dir.url.canonical)
    }

    @Test("View as Columns (⌘3) switches the view and is remembered")
    func viewMode() throws {
        let model = makeModel()
        KeyActionRunner(browser: model, window: nil).perform(.viewAsColumns)
        #expect(model.viewMode == .columns)
        #expect(makeModel().viewMode == .columns)
        #expect(KeyAction.viewAsColumns.defaultShortcut?.text == "cmd+3")
    }
}
