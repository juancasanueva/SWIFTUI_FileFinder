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
        actions = FileActions(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))))
        actions.undoManager = undoManager
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - Rename

    @Test("Rename changes the name on disk and undo restores it")
    func renameAndUndo() throws {
        let original = try dir.file("draft.txt", bytes: 3)

        let renamed = try actions.rename(original, to: "final.txt")

        #expect(renamed.lastPathComponent == "final.txt")
        #expect(exists(renamed) && !exists(original))

        undoManager.undo()
        #expect(exists(original) && !exists(renamed))

        undoManager.redo()
        #expect(exists(renamed) && !exists(original))
    }

    @Test("Rename rejects empty names and names containing a slash", arguments: ["", "   ", "a/b"])
    func renameRejectsInvalidNames(name: String) throws {
        let original = try dir.file("draft.txt")
        #expect(throws: FileActionError.invalidName) { try actions.rename(original, to: name) }
        #expect(exists(original))
        #expect(!undoManager.canUndo)
    }

    @Test("Rename refuses to overwrite an existing item")
    func renameRefusesOverwrite() throws {
        let original = try dir.file("a.txt", bytes: 1)
        let other = try dir.file("b.txt", bytes: 2)
        #expect(throws: FileActionError.nameTaken("b.txt")) { try actions.rename(original, to: "b.txt") }
        #expect(exists(original))
        #expect(try Data(contentsOf: other).count == 2)
    }

    // MARK: - Copy

    @Test("Copying into the same folder uses Finder's copy naming")
    func copyIntoSameFolder() throws {
        let source = try dir.file("photo.jpg", bytes: 4)

        let first = try actions.copy([source], into: dir.url)
        let second = try actions.copy([source], into: dir.url)

        #expect(first.map(\.lastPathComponent) == ["photo copy.jpg"])
        #expect(second.map(\.lastPathComponent) == ["photo copy 2.jpg"])
        #expect(exists(source))
    }

    @Test("Copying into another folder with a name clash keeps both")
    func copyKeepsBoth() throws {
        let source = try dir.file("a/report.pdf")
        let target = try dir.folder("b")
        try dir.file("b/report.pdf")

        let copies = try actions.copy([source], into: target)

        #expect(copies.map(\.lastPathComponent) == ["report 2.pdf"])
    }

    @Test("Undoing a copy removes the copy and keeps the original")
    func undoCopy() throws {
        let source = try dir.file("a/report.pdf")
        let target = try dir.folder("b")

        let copies = try actions.copy([source], into: target)
        undoManager.undo()

        #expect(!exists(copies[0]))
        #expect(exists(source))
    }

    @Test("Copying a folder into itself is refused without creating anything")
    func copyIntoItself() throws {
        let folder = try dir.folder("D")
        try dir.file("D/in.txt")
        let nested = try dir.folder("D/inner")

        #expect(throws: FileActionError.cannotCopyIntoItself) { try actions.copy([folder], into: folder) }
        #expect(throws: FileActionError.cannotCopyIntoItself) { try actions.copy([folder], into: nested) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["in.txt", "inner"])
        #expect(!undoManager.canUndo)
    }

    @Test("Moving a folder into itself is refused")
    func moveIntoItself() throws {
        let folder = try dir.folder("D")
        let nested = try dir.folder("D/inner")

        #expect(throws: FileActionError.cannotCopyIntoItself) { try actions.move([folder], into: nested) }
        #expect(exists(folder))
    }

    // MARK: - Move

    @Test("Move relocates items and undo moves them back")
    func moveAndUndo() throws {
        let source = try dir.file("a/song.mp3", bytes: 7)
        let target = try dir.folder("b")

        let moved = try actions.move([source], into: target)

        #expect(moved == [target.appendingPathComponent("song.mp3")])
        #expect(!exists(source) && exists(moved[0]))

        undoManager.undo()
        #expect(exists(source) && !exists(moved[0]))
    }

    @Test("Moving an item into its own folder is a no-op")
    func moveIntoSameFolder() throws {
        let source = try dir.file("song.mp3")
        let moved = try actions.move([source], into: dir.url)
        #expect(moved.isEmpty)
        #expect(exists(source))
        #expect(!undoManager.canUndo)
    }

    // MARK: - Trash

    @Test("Trash removes the item and undo puts it back")
    func trashAndUndo() throws {
        let file = try dir.file("old.log", bytes: 9)

        try actions.trash([file])
        #expect(!exists(file))

        undoManager.undo()
        #expect(exists(file))
        #expect(try Data(contentsOf: file).count == 9)
    }

    // MARK: - Clipboard

    @Test("Copy then paste duplicates the files")
    func copyPaste() throws {
        let source = try dir.file("a/x.txt")
        let target = try dir.folder("b")

        actions.copyToClipboard([source])
        let pasted = try actions.paste(into: target)

        #expect(pasted == [target.appendingPathComponent("x.txt")])
        #expect(exists(source))
    }

    @Test("Cut then paste moves the files")
    func cutPaste() throws {
        let source = try dir.file("a/x.txt")
        let target = try dir.folder("b")

        actions.cutToClipboard([source])
        let pasted = try actions.paste(into: target)

        #expect(pasted == [target.appendingPathComponent("x.txt")])
        #expect(!exists(source))
    }

    @Test("Files copied by another app (e.g. Finder) paste as copies")
    func pasteFromExternalCopy() throws {
        let pasteboard = NSPasteboard(name: .init("FileFinderTests-\(UUID())"))
        let actions = FileActions(clipboard: FileClipboard(pasteboard: pasteboard))
        let source = try dir.file("a/x.txt")
        let target = try dir.folder("b")

        pasteboard.clearContents()
        pasteboard.writeObjects([source as NSURL])
        let pasted = try actions.paste(into: target)

        #expect(pasted.count == 1)
        #expect(exists(source))
    }

    @Test("Paste-and-move (⌥⌘V) moves files that were only copied")
    func pasteForcingMove() throws {
        let source = try dir.file("a/x.txt")
        let target = try dir.folder("b")

        actions.copyToClipboard([source])
        let pasted = try actions.paste(into: target, forceMove: true)

        #expect(pasted == [target.appendingPathComponent("x.txt")])
        #expect(!exists(source))
    }

    @Test("Cut then paste into the same folder keeps the clipboard")
    func cutPasteSameFolderKeepsClipboard() throws {
        let source = try dir.file("x.txt")

        actions.cutToClipboard([source])
        #expect(try actions.paste(into: dir.url).isEmpty)

        #expect(actions.canPaste)
        #expect(exists(source))
    }

    @Test("Pasting with an empty clipboard does nothing")
    func pasteEmpty() throws {
        let target = try dir.folder("b")
        #expect(try actions.paste(into: target).isEmpty)
    }
}
