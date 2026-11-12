import AppKit
import Foundation
import Testing
@testable import FileFinder

@MainActor
@Suite("File actions and undo")
struct FileActionsTests {
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

    private func undo() async {
        undoManager.undo()
        await actions.waitForPendingWork()
    }

    private func redo() async {
        undoManager.redo()
        await actions.waitForPendingWork()
    }

    // MARK: - Rename

    @Test("Rename changes the name on disk and undo restores it")
    func renameAndUndo() async throws {
        let original = try dir.file("draft.txt", bytes: 3)

        let renamed = try await actions.rename(original, to: "final.txt")

        #expect(renamed.lastPathComponent == "final.txt")
        #expect(exists(renamed) && !exists(original))

        await undo()
        #expect(exists(original) && !exists(renamed))

        await redo()
        #expect(exists(renamed) && !exists(original))
    }

    @Test("Rename rejects empty names and names containing a slash", arguments: ["", "   ", "a/b"])
    func renameRejectsInvalidNames(name: String) async throws {
        let original = try dir.file("draft.txt")
        await #expect(throws: FileActionError.invalidName) { try await actions.rename(original, to: name) }
        #expect(exists(original))
        #expect(!undoManager.canUndo)
    }

    @Test("Rename refuses to overwrite an existing item")
    func renameRefusesOverwrite() async throws {
        let original = try dir.file("a.txt", bytes: 1)
        let other = try dir.file("b.txt", bytes: 2)
        await #expect(throws: FileActionError.nameTaken("b.txt")) { try await actions.rename(original, to: "b.txt") }
        #expect(exists(original))
        #expect(try Data(contentsOf: other).count == 2)
    }

    @Test("An undo that can't be applied is reported instead of failing silently")
    func failedUndoIsReported() async throws {
        var reported: [String] = []
        actions.onBackgroundError = { reported.append($0) }
        let original = try dir.file("draft.txt")
        let renamed = try await actions.rename(original, to: "final.txt")
        try dir.file("draft.txt")  // the old name is taken again

        await undo()

        #expect(reported.count == 1)
        #expect(exists(renamed))
    }

    // MARK: - Copy

    @Test("Copying into the same folder uses Finder's copy naming")
    func copyIntoSameFolder() async throws {
        let source = try dir.file("photo.jpg", bytes: 4)

        let first = try await actions.copy([source], into: dir.url)
        let second = try await actions.copy([source], into: dir.url)

        #expect(first.map(\.lastPathComponent) == ["photo copy.jpg"])
        #expect(second.map(\.lastPathComponent) == ["photo copy 2.jpg"])
        #expect(exists(source))
    }

    @Test("Copying into another folder with a name clash keeps both")
    func copyKeepsBoth() async throws {
        let source = try dir.file("a/report.pdf")
        let target = try dir.folder("b")
        try dir.file("b/report.pdf")

        let copies = try await actions.copy([source], into: target)

        #expect(copies.map(\.lastPathComponent) == ["report 2.pdf"])
    }

    @Test("Undoing a copy removes the copy, and redo brings it back")
    func undoRedoCopy() async throws {
        let source = try dir.file("a/report.pdf", bytes: 5)
        let target = try dir.folder("b")

        let copies = try await actions.copy([source], into: target)
        await undo()

        #expect(!exists(copies[0]))
        #expect(exists(source))

        await redo()
        #expect(exists(copies[0]))
        #expect(try Data(contentsOf: copies[0]).count == 5)
    }

    @Test("Copying a folder into itself is refused without creating anything")
    func copyIntoItself() async throws {
        let folder = try dir.folder("D")
        try dir.file("D/in.txt")
        let nested = try dir.folder("D/inner")

        await #expect(throws: FileActionError.cannotCopyIntoItself) { try await actions.copy([folder], into: folder) }
        await #expect(throws: FileActionError.cannotCopyIntoItself) { try await actions.copy([folder], into: nested) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["in.txt", "inner"])
        #expect(!undoManager.canUndo)
    }

    // MARK: - Move

    @Test("Moving a folder into itself is refused")
    func moveIntoItself() async throws {
        let folder = try dir.folder("D")
        let nested = try dir.folder("D/inner")

        await #expect(throws: FileActionError.cannotCopyIntoItself) { try await actions.move([folder], into: nested) }
        #expect(exists(folder))
    }

    @Test("Move relocates items and undo moves them back")
    func moveAndUndo() async throws {
        let source = try dir.file("a/song.mp3", bytes: 7)
        let target = try dir.folder("b")

        let moved = try await actions.move([source], into: target)

        #expect(moved == [target.appendingPathComponent("song.mp3")])
        #expect(!exists(source) && exists(moved[0]))

        await undo()
        #expect(exists(source) && !exists(moved[0]))
    }

    @Test("Moving two items with the same name from different folders keeps both")
    func moveSameNames() async throws {
        let first = try dir.file("a/x.txt")
        let second = try dir.file("b/x.txt")
        let target = try dir.folder("c")

        let moved = try await actions.move([first, second], into: target)

        #expect(moved.map(\.lastPathComponent) == ["x.txt", "x 2.txt"])
    }

    @Test("Moving an item into its own folder is a no-op")
    func moveIntoSameFolder() async throws {
        let source = try dir.file("song.mp3")
        let moved = try await actions.move([source], into: dir.url)
        #expect(moved.isEmpty)
        #expect(exists(source))
        #expect(!undoManager.canUndo)
    }

    // MARK: - Trash

    @Test("Trash removes the item and undo puts it back")
    func trashAndUndo() async throws {
        let file = try dir.file("old.log", bytes: 9)

        try await actions.trash([file])
        #expect(!exists(file))

        await undo()
        #expect(exists(file))
        #expect(try Data(contentsOf: file).count == 9)
    }

    @Test("Undoing a trash onto a name that is taken again reports it and keeps the new file")
    func trashUndoConflictIsReported() async throws {
        var reported: [String] = []
        actions.onBackgroundError = { reported.append($0) }
        let file = try dir.file("old.log", bytes: 9)
        try await actions.trash([file])
        try dir.file("old.log", bytes: 1)

        await undo()

        #expect(reported.count == 1)
        #expect(try Data(contentsOf: file).count == 1)
    }

    // MARK: - New folder

    @Test("New Folder uses Finder's untitled naming")
    func newFolderNaming() async throws {
        let first = try await actions.createFolder(in: dir.url)
        let second = try await actions.createFolder(in: dir.url)

        #expect(first.lastPathComponent == "untitled folder")
        #expect(second.lastPathComponent == "untitled folder 2")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test("Undoing New Folder removes the empty folder, and redo creates it again")
    func undoRedoNewFolder() async throws {
        let folder = try await actions.createFolder(in: dir.url)

        await undo()
        #expect(!exists(folder))

        await redo()
        #expect(exists(folder))
    }

    @Test("Undoing New Folder leaves the folder in place once something was put in it")
    func undoNewFolderKeepsContents() async throws {
        var reported: [String] = []
        actions.onBackgroundError = { reported.append($0) }
        let folder = try await actions.createFolder(in: dir.url)
        try dir.file("untitled folder/keep.txt", bytes: 3)

        await undo()

        #expect(exists(folder.appendingPathComponent("keep.txt")))
        #expect(reported.count == 1)
    }

    // MARK: - New Markdown file

    @Test("New Markdown File creates an empty new.md, then new 2.md")
    func newMarkdownFileNaming() async throws {
        let first = try await actions.createMarkdownFile(in: dir.url)
        let second = try await actions.createMarkdownFile(in: dir.url)

        #expect(first.lastPathComponent == "new.md")
        #expect(second.lastPathComponent == "new 2.md")
        #expect(try Data(contentsOf: first).isEmpty)
    }

    @Test("Undoing New Markdown File removes the empty file, and redo creates it again")
    func undoRedoNewMarkdownFile() async throws {
        let file = try await actions.createMarkdownFile(in: dir.url)
        #expect(undoManager.undoActionName == "New Markdown File")

        await undo()
        #expect(!exists(file))
        #expect(undoManager.redoActionName == "New Markdown File")

        await redo()
        #expect(exists(file))
        #expect(try Data(contentsOf: file).isEmpty)
        #expect(undoManager.undoActionName == "New Markdown File")
    }

    @Test("Undoing New Markdown File leaves the file in place once something was written to it")
    func undoNewMarkdownFileKeepsContents() async throws {
        var reported: [String] = []
        actions.onBackgroundError = { reported.append($0) }
        let file = try await actions.createMarkdownFile(in: dir.url)
        try Data("notes".utf8).write(to: file)

        await undo()

        #expect(try Data(contentsOf: file) == Data("notes".utf8))
        #expect(reported.count == 1)
    }

    // MARK: - New Text file

    @Test("New Text File creates an empty new.txt, then new 2.txt")
    func newTextFileNaming() async throws {
        let first = try await actions.createTextFile(in: dir.url)
        let second = try await actions.createTextFile(in: dir.url)

        #expect(first.lastPathComponent == "new.txt")
        #expect(second.lastPathComponent == "new 2.txt")
        #expect(try Data(contentsOf: first).isEmpty)
    }

    @Test("Undoing New Text File removes the empty file, and redo creates it again")
    func undoRedoNewTextFile() async throws {
        let file = try await actions.createTextFile(in: dir.url)
        #expect(undoManager.undoActionName == "New Text File")

        await undo()
        #expect(!exists(file))
        #expect(undoManager.redoActionName == "New Text File")

        await redo()
        #expect(exists(file))
        #expect(try Data(contentsOf: file).isEmpty)
        #expect(undoManager.undoActionName == "New Text File")
    }

    // MARK: - Ordering

    @Test("Undoing a move and a rename back to back restores the original name and place")
    func quickDoubleUndo() async throws {
        let original = try dir.file("src/a.txt", bytes: 2)
        let target = try dir.folder("dst")
        let renamed = try await actions.rename(original, to: "b.txt")
        _ = try await actions.move([renamed], into: target)

        undoManager.undo()
        undoManager.undo()
        await actions.waitForPendingWork()

        #expect(exists(original))
        #expect(!exists(target.appendingPathComponent("b.txt")))
    }

    @Test("Two copies started at once both succeed with distinct names")
    func concurrentCopies() async throws {
        let source = try dir.file("big.bin", bytes: 2_000_000)
        let target = try dir.folder("dst")

        async let first = actions.copy([source], into: target)
        async let second = actions.copy([source], into: target)
        let results = try await [first, second].flatMap { $0 }

        #expect(Set(results.map(\.lastPathComponent)) == ["big.bin", "big 2.bin"])
        #expect(results.allSatisfy(exists))
    }

    @Test("Redoing a copy never replaces or trashes a file that took the copy's name")
    func redoCopyKeepsNewerFile() async throws {
        var reported: [String] = []
        actions.onBackgroundError = { reported.append($0) }
        let source = try dir.file("a.txt", bytes: 1)
        let target = try dir.folder("dst")
        let copy = try #require(try await actions.copy([source], into: target).first)
        await undo()
        try dir.file("dst/a.txt", bytes: 7)  // e.g. a download lands with the same name

        await redo()
        #expect(reported.count == 1)
        #expect(try Data(contentsOf: copy).count == 7)

        await undo()
        #expect(try Data(contentsOf: copy).count == 7)
    }

    @Test("After an undo that stops partway, redo only re-applies what the undo moved back")
    func partialUndoThenRedo() async throws {
        var reported: [String] = []
        actions.onBackgroundError = { reported.append($0) }
        let first = try dir.file("src/a.txt", bytes: 1)
        let second = try dir.file("src/b.txt", bytes: 2)
        let target = try dir.folder("dst")
        _ = try await actions.move([first, second], into: target)
        try dir.file("src/b.txt", bytes: 9)   // blocks b from going back

        await undo()
        #expect(exists(first))
        #expect(reported.count == 1)

        await redo()
        #expect(reported.count == 1)   // redo doesn't try to move b, which never came back
        #expect(!exists(first))
        #expect(exists(target.appendingPathComponent("a.txt")))
        #expect(exists(target.appendingPathComponent("b.txt")))
        #expect(try Data(contentsOf: second).count == 9)
    }

    // MARK: - Clipboard

    @Test("Copy then paste duplicates the files")
    func copyPaste() async throws {
        let source = try dir.file("a/x.txt")
        let target = try dir.folder("b")

        actions.copyToClipboard([source])
        let pasted = try await actions.paste(into: target)

        #expect(pasted == [target.appendingPathComponent("x.txt")])
        #expect(exists(source))
    }

    @Test("Cut then paste moves the files")
    func cutPaste() async throws {
        let source = try dir.file("a/x.txt")
        let target = try dir.folder("b")

        actions.cutToClipboard([source])
        let pasted = try await actions.paste(into: target)

        #expect(pasted == [target.appendingPathComponent("x.txt")])
        #expect(!exists(source))
    }

    @Test("A cut-paste that fails partway keeps the unmoved items on the clipboard for a retry")
    func partialCutPasteCanBeRetried() async throws {
        let movable = try dir.file("a/one.txt")
        let locked = try dir.file("locked/two.txt")
        let lockedFolder = locked.deletingLastPathComponent()
        let target = try dir.folder("b")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedFolder.path) }

        actions.cutToClipboard([movable, locked])
        await #expect(throws: (any Error).self) { try await actions.paste(into: target) }

        let clipboard = actions.clipboard.read()
        #expect(clipboard.urls.map(\.lastPathComponent) == ["two.txt"])
        #expect(clipboard.isCut)
        #expect(exists(target.appendingPathComponent("one.txt")))
    }

    @Test("Paste-and-move (⌥⌘V) moves files that were only copied")
    func pasteForcingMove() async throws {
        let source = try dir.file("a/x.txt")
        let target = try dir.folder("b")

        actions.copyToClipboard([source])
        let pasted = try await actions.paste(into: target, forceMove: true)

        #expect(pasted == [target.appendingPathComponent("x.txt")])
        #expect(!exists(source))
    }

    @Test("Files copied by another app (e.g. Finder) paste as copies")
    func pasteFromExternalCopy() async throws {
        let pasteboard = NSPasteboard(name: .init("FileFinderTests-\(UUID())"))
        let actions = FileActions.testing(clipboard: FileClipboard(pasteboard: pasteboard))
        let source = try dir.file("a/x.txt")
        let target = try dir.folder("b")

        pasteboard.clearContents()
        pasteboard.writeObjects([source as NSURL])
        let pasted = try await actions.paste(into: target)

        #expect(pasted.count == 1)
        #expect(exists(source))
    }

    @Test("Cut then paste into the same folder keeps the clipboard")
    func cutPasteSameFolderKeepsClipboard() async throws {
        let source = try dir.file("x.txt")

        actions.cutToClipboard([source])
        #expect(try await actions.paste(into: dir.url).isEmpty)

        #expect(actions.canPaste)
        #expect(exists(source))
    }

    @Test("Pasting with an empty clipboard does nothing")
    func pasteEmpty() async throws {
        let target = try dir.folder("b")
        #expect(try await actions.paste(into: target).isEmpty)
    }
}
