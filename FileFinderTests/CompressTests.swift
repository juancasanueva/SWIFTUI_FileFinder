import AppKit
import Foundation
import Testing
@testable import FileFinder

@MainActor
@Suite("Compress to ZIP")
struct CompressTests {
    let dir: TemporaryDirectory
    let undoManager: UndoManager
    let actions: FileActions

    init() throws {
        dir = try TemporaryDirectory()
        undoManager = UndoManager()
        undoManager.groupsByEvent = false
        actions = FileActions.testing(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))))
        actions.undoManager = undoManager
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The paths inside a ZIP, as `unzip -Z1` lists them.
    private func entries(_ archive: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").map(String.init).sorted()
    }

    @Test("One item becomes name.zip next to it, folders with their contents; the original stays")
    func oneItem() async throws {
        let report = try dir.file("report.pdf", bytes: 10)
        let docs = try dir.folder("Docs")
        try dir.file("Docs/a.txt", bytes: 3)

        let fileArchive = try await actions.compress([report], in: dir.url)
        #expect(fileArchive.lastPathComponent == "report.pdf.zip")
        #expect(try entries(fileArchive) == ["report.pdf"])
        #expect(exists(report))

        let folderArchive = try await actions.compress([docs], in: dir.url)
        #expect(folderArchive.lastPathComponent == "Docs.zip")
        #expect(try entries(folderArchive) == ["Docs/", "Docs/a.txt"])
    }

    @Test("Several items become Archive.zip, then Archive 2.zip")
    func severalItems() async throws {
        let a = try dir.file("a.txt", bytes: 1)
        let b = try dir.file("b.txt", bytes: 1)

        let first = try await actions.compress([a, b], in: dir.url)
        let second = try await actions.compress([a, b], in: dir.url)
        #expect(first.lastPathComponent == "Archive.zip")
        #expect(second.lastPathComponent == "Archive 2.zip")
        #expect(try entries(first) == ["a.txt", "b.txt"])
    }

    @Test("Undo moves the archive to the Trash, and redo makes it again")
    func undoRedo() async throws {
        let a = try dir.file("a.txt", bytes: 1)
        let archive = try await actions.compress([a], in: dir.url)
        #expect(undoManager.undoActionName == "Compress")

        undoManager.undo()
        await actions.waitForPendingWork()
        #expect(!exists(archive))
        #expect(exists(a))

        undoManager.redo()
        await actions.waitForPendingWork()
        #expect(try entries(archive) == ["a.txt"])
    }

    @Test("Compress selects the new archive; it is offered for a selection, never in a workspace")
    func paneCompress() async throws {
        let a = try dir.file("a.txt", bytes: 1)
        let defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        let model = BrowserModel(start: dir.url, actions: actions, defaults: defaults)
        await model.reload()
        #expect(!KeyActionRunner(browser: model, window: nil).canPerform(.compress))

        model.selection = [a.canonical]
        let runner = KeyActionRunner(browser: model, window: nil)
        #expect(runner.canPerform(.compress))
        #expect(runner.title(.compress) == "Compress \u{201C}a.txt\u{201D}")

        await model.compressSelection()
        #expect(model.selection == [dir.url.appending(path: "a.txt.zip").canonical])

        let store = WorkspaceStore(fileURL: dir.url.appending(path: "store/workspaces.json"))
        let workspace = store.create(named: "W")
        store.add([a], to: workspace.id)
        let inWorkspace = BrowserModel(
            start: dir.url, actions: actions, defaults: defaults, workspaces: store, showing: workspace.id)
        await inWorkspace.reload()
        inWorkspace.selection = Set(inWorkspace.items.map(\.url))
        #expect(!KeyActionRunner(browser: inWorkspace, window: nil).canPerform(.compress))
    }
}
