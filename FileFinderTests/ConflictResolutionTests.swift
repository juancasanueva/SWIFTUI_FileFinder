import AppKit
import Foundation
import Testing
@testable import FileFinder

@MainActor
@Suite("Name conflicts")
struct ConflictResolutionTests {
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
    private func size(_ url: URL) throws -> Int { try Data(contentsOf: url).count }

    private func undo() async {
        undoManager.undo()
        await actions.waitForPendingWork()
    }

    /// Answers every conflict with `resolution` and records what was asked.
    private func answering(
        _ resolution: ConflictResolution, applyToAll: Bool = false, asked: Recorder
    ) -> ConflictResolver {
        { conflict in
            asked.names.append(conflict.existing.lastPathComponent)
            return ConflictDecision(resolution: resolution, applyToAll: applyToAll)
        }
    }

    @Test("Keep both gives the incoming item a numbered name")
    func keepBoth() async throws {
        let source = try dir.file("a/x.txt", bytes: 1)
        let target = try dir.folder("b")
        try dir.file("b/x.txt", bytes: 2)
        let asked = Recorder()

        let copies = try await actions.copy([source], into: target, resolveConflicts: answering(.keepBoth, asked: asked))

        #expect(asked.names == ["x.txt"])
        #expect(copies.map(\.lastPathComponent) == ["x 2.txt"])
        #expect(try size(target.appending(path: "x.txt")) == 2)
    }

    @Test("Skip leaves the existing item alone and transfers nothing")
    func skip() async throws {
        let source = try dir.file("a/x.txt", bytes: 1)
        let target = try dir.folder("b")
        try dir.file("b/x.txt", bytes: 2)

        let moved = try await actions.move([source], into: target, resolveConflicts: answering(.skip, asked: Recorder()))

        #expect(moved.isEmpty)
        #expect(exists(source))
        #expect(try size(target.appending(path: "x.txt")) == 2)
    }

    @Test("Replace on copy trashes the existing item; undo brings it back")
    func replaceOnCopy() async throws {
        let source = try dir.file("a/x.txt", bytes: 1)
        let target = try dir.folder("b")
        let existing = try dir.file("b/x.txt", bytes: 2)

        let copies = try await actions.copy([source], into: target, resolveConflicts: answering(.replace, asked: Recorder()))

        #expect(copies == [existing])
        #expect(try size(existing) == 1)

        await undo()
        #expect(try size(existing) == 2)
        #expect(exists(source))
    }

    @Test("Replace on move trashes the existing item; undo moves the item back and restores the old one")
    func replaceOnMove() async throws {
        let source = try dir.file("a/x.txt", bytes: 1)
        let target = try dir.folder("b")
        let existing = try dir.file("b/x.txt", bytes: 2)

        _ = try await actions.move([source], into: target, resolveConflicts: answering(.replace, asked: Recorder()))
        #expect(!exists(source))
        #expect(try size(existing) == 1)

        await undo()
        #expect(try size(source) == 1)
        #expect(try size(existing) == 2)
    }

    @Test("Apply to all answers the remaining conflicts of the batch without asking again")
    func applyToAll() async throws {
        let sources = try ["p", "q", "r"].map { try dir.file("a/\($0).txt", bytes: 1) }
        let target = try dir.folder("b")
        for name in ["p", "q", "r"] { try dir.file("b/\(name).txt", bytes: 2) }
        let asked = Recorder()

        let copies = try await actions.copy(
            sources, into: target, resolveConflicts: answering(.skip, applyToAll: true, asked: asked))

        #expect(asked.names == ["p.txt"])
        #expect(copies.isEmpty)
    }

    @Test("Conflicts report how many items of the batch are still to come")
    func remainingCount() async throws {
        let sources = try ["p", "q"].map { try dir.file("a/\($0).txt") }
        let target = try dir.folder("b")
        try dir.file("b/p.txt")
        var remaining: [Int] = []

        _ = try await actions.copy(sources, into: target) { conflict in
            remaining.append(conflict.remaining)
            return ConflictDecision(resolution: .skip)
        }

        #expect(remaining == [1])
    }

    @Test("Duplicating inside the same folder never asks")
    func sameFolderDoesNotAsk() async throws {
        let source = try dir.file("x.txt")
        let asked = Recorder()

        let copies = try await actions.copy([source], into: dir.url, resolveConflicts: answering(.replace, asked: asked))

        #expect(asked.names.isEmpty)
        #expect(copies.map(\.lastPathComponent) == ["x copy.txt"])
    }

    @Test("Replacing the folder that contains the item being moved is refused")
    func replacingParentIsRefused() async throws {
        let source = try dir.folder("x/x")   // moving x/x into the top folder would replace its own parent
        try dir.file("x/x/keep.txt")

        await #expect(throws: FileActionError.cannotReplaceContainingFolder("x")) {
            try await actions.move([source], into: dir.url, resolveConflicts: answering(.replace, asked: Recorder()))
        }
        #expect(exists(source.appending(path: "keep.txt")))
    }
}

@MainActor
final class Recorder {
    var names: [String] = []
}

@MainActor
@Suite("Conflict prompt")
struct ConflictPromptTests {
    @Test("Pasting into a folder with a clash asks, and the answer is applied")
    func pasteAsks() async throws {
        let dir = try TemporaryDirectory()
        let source = try dir.file("a/x.txt", bytes: 1)
        let target = try dir.folder("b")
        let existing = try dir.file("b/x.txt", bytes: 2)
        let defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        let actions = FileActions(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))))
        let model = BrowserModel(start: target, actions: actions, defaults: defaults)
        actions.copyToClipboard([source])

        let pasting = Task { await model.paste() }
        while model.pendingConflict == nil { await Task.yield() }
        #expect(model.pendingConflict?.existing.lastPathComponent == "x.txt")

        model.answerConflict(ConflictDecision(resolution: .replace))
        await pasting.value

        #expect(model.pendingConflict == nil)
        #expect(try Data(contentsOf: existing).count == 1)
    }
}
