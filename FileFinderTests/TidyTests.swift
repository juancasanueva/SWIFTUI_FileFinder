import AppKit
import Foundation
import Testing
@testable import FileFinder

@MainActor
@Suite("Tidy")
struct TidyTests {
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

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.url.appendingPathComponent(path).path)
    }

    private func undo() async {
        undoManager.undo()
        await actions.waitForPendingWork()
    }

    private func redo() async {
        undoManager.redo()
        await actions.waitForPendingWork()
    }

    // MARK: - Kinds

    @Test("Each file goes to the folder for its kind", arguments: [
        ("clip.mov", FileKind.videos), ("talk.MP4", .videos),
        ("photo.jpg", .images), ("shot.PNG", .images), ("pic.heic", .images),
        ("invoice.pdf", .pdfs),
        ("letter.docx", .documents), ("notes.txt", .documents), ("sheet.xlsx", .documents),
        ("deck.key", .documents), ("report.pages", .documents), ("data.csv", .documents),
        ("Setup.dmg", .installers), ("tool.pkg", .installers),
        ("archive.zip", .other), ("song.mp3", .other), ("main.swift", .other), ("README", .other),
    ])
    func kinds(name: String, kind: FileKind) {
        #expect(FileKind.of(URL(filePath: "/tmp/\(name)")) == kind)
    }

    @Test("Kind folders use the reference names in a fixed order")
    func kindNames() {
        #expect(FileKind.allCases.map(\.folderName) == ["Videos", "Images", "PDFs", "Documents", "Installers", "Other"])
    }

    // MARK: - Plan

    @Test("The plan covers loose files only, grouped by kind in a fixed order")
    func planGroupsLooseFiles() throws {
        try dir.file("b.pdf")
        try dir.file("a.jpg")
        try dir.file("c.jpg")
        try dir.file("x.zip")
        try dir.folder("Projects")
        try dir.file("Projects/inside.pdf")
        try dir.folder("Tool.app")
        try dir.file(".hidden.pdf")
        try dir.file("big.mov.crdownload")
        try dir.folder("movie.download")

        let plan = try TidyPlan.make(for: dir.url)

        #expect(plan.groups.map(\.kind) == [.images, .pdfs, .other])
        #expect(plan.groups[0].files.map(\.lastPathComponent) == ["a.jpg", "c.jpg"])
        #expect(plan.groups[1].files.map(\.lastPathComponent) == ["b.pdf"])
        #expect(Set(plan.groups[2].files.map(\.lastPathComponent)) == ["Tool.app", "x.zip"])
        #expect(plan.fileCount == 5)
        #expect(plan.groups.allSatisfy { !$0.folderExists })
        #expect(plan.groups[0].folder.lastPathComponent == "Images")
    }

    @Test("An existing kind folder is reused, and a kind whose name is taken by a file is left out")
    func planReusesFoldersAndSkipsBlockedKinds() throws {
        try dir.folder("Images")
        try dir.file("a.jpg")
        try dir.file("PDFs")       // a file without extension named like a kind folder
        try dir.file("b.pdf")

        let plan = try TidyPlan.make(for: dir.url)

        #expect(plan.groups.map(\.kind) == [.images, .other])
        #expect(plan.groups[0].folderExists)
        #expect(plan.groups[1].files.map(\.lastPathComponent) == ["PDFs"])
        #expect(plan.blockedKinds == [.pdfs])
    }

    @Test("A folder with nothing loose has an empty plan")
    func emptyPlan() throws {
        try dir.folder("Projects")
        let plan = try TidyPlan.make(for: dir.url)
        #expect(plan.isEmpty)
        #expect(plan.fileCount == 0)
    }

    // MARK: - Tidying

    @Test("Tidy moves every planned file into its kind folder")
    func tidyMovesFiles() async throws {
        try dir.file("a.jpg", bytes: 2)
        try dir.file("b.pdf")
        try dir.file("x.zip")

        let moved = try await actions.tidy(try TidyPlan.make(for: dir.url))

        #expect(moved.count == 3)
        #expect(exists("Images/a.jpg") && exists("PDFs/b.pdf") && exists("Other/x.zip"))
        #expect(!exists("a.jpg") && !exists("b.pdf") && !exists("x.zip"))
        #expect(undoManager.undoActionName == "Tidy")
    }

    @Test("A name clash inside an existing kind folder keeps both files")
    func tidyKeepsBothOnClash() async throws {
        try dir.file("Images/a.jpg", bytes: 1)
        try dir.file("a.jpg", bytes: 2)

        try await actions.tidy(try TidyPlan.make(for: dir.url))

        #expect(try Data(contentsOf: dir.url.appendingPathComponent("Images/a.jpg")).count == 1)
        #expect(try Data(contentsOf: dir.url.appendingPathComponent("Images/a 2.jpg")).count == 2)
    }

    @Test("Files gone since the preview are skipped")
    func tidySkipsStaleFiles() async throws {
        let gone = try dir.file("gone.pdf")
        try dir.file("kept.pdf")
        let plan = try TidyPlan.make(for: dir.url)
        try FileManager.default.removeItem(at: gone)

        let moved = try await actions.tidy(plan)

        #expect(moved.map(\.lastPathComponent) == ["kept.pdf"])
        #expect(exists("PDFs/kept.pdf"))
    }

    @Test("One undo puts every file back and removes the folders tidy created; redo tidies again")
    func undoAndRedo() async throws {
        try dir.folder("Images")
        try dir.file("Images/old.png")
        try dir.file("a.jpg")
        try dir.file("b.pdf")
        try await actions.tidy(try TidyPlan.make(for: dir.url))

        await undo()

        #expect(exists("a.jpg") && exists("b.pdf"))
        #expect(!exists("PDFs"))                       // created by tidy, empty again
        #expect(exists("Images/old.png"))              // was already there: never trashed
        #expect(!exists("Images/a.jpg"))
        #expect(!undoManager.canUndo)
        #expect(undoManager.redoActionName == "Tidy")

        await redo()

        #expect(exists("Images/a.jpg") && exists("PDFs/b.pdf"))
        #expect(!exists("a.jpg") && !exists("b.pdf"))

        await undo()
        #expect(exists("a.jpg") && exists("b.pdf") && !exists("PDFs"))
    }

    @Test("Undo leaves a created kind folder in place once something else was put in it")
    func undoKeepsNonEmptyFolder() async throws {
        var reported: [String] = []
        actions.onBackgroundError = { reported.append($0) }
        try dir.file("b.pdf")
        try await actions.tidy(try TidyPlan.make(for: dir.url))
        try dir.file("PDFs/new.pdf")

        await undo()

        #expect(exists("b.pdf"))
        #expect(exists("PDFs/new.pdf"))
        #expect(reported.count == 1)

        await redo()   // the folder is still there: redo just moves the file again
        #expect(exists("PDFs/b.pdf") && !exists("b.pdf"))
        #expect(reported.count == 1)
    }

    @Test("Tidying an empty plan does nothing and adds no undo step")
    func emptyTidy() async throws {
        let moved = try await actions.tidy(try TidyPlan.make(for: dir.url))
        #expect(moved.isEmpty)
        #expect(!undoManager.canUndo)
    }
}
