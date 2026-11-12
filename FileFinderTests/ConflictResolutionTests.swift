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
        actions = FileActions.testing(
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

        #expect(remaining == [0])
    }

    @Test("Duplicating inside the same folder never asks")
    func sameFolderDoesNotAsk() async throws {
        let source = try dir.file("x.txt")
        let asked = Recorder()

        let copies = try await actions.copy([source], into: dir.url, resolveConflicts: answering(.replace, asked: asked))

        #expect(asked.names.isEmpty)
        #expect(copies.map(\.lastPathComponent) == ["x copy.txt"])
    }

    @Test("When a replacing copy fails, the item it was replacing is put back and the rest isn't trashed")
    func failedReplaceRollsBack() async throws {
        let unreadable = try dir.file("a/p.txt", bytes: 1)
        let readable = try dir.file("a/q.txt", bytes: 1)
        let target = try dir.folder("b")
        let oldP = try dir.file("b/p.txt", bytes: 2)
        let oldQ = try dir.file("b/q.txt", bytes: 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

        await #expect(throws: (any Error).self) {
            try await actions.copy([unreadable, readable], into: target,
                                   resolveConflicts: answering(.replace, applyToAll: true, asked: Recorder()))
        }

        #expect(try size(oldP) == 2)   // put back after its replacement failed
        #expect(try size(oldQ) == 2)   // never touched: the batch stopped first
    }

    @Test("An item that is itself part of the batch is never replaced")
    func batchSourceIsNotReplaced() async throws {
        let top = try dir.file("x.txt", bytes: 1)
        let nested = try dir.file("a/x.txt", bytes: 2)
        let asked = Recorder()

        let copies = try await actions.copy([top, nested], into: dir.url, resolveConflicts: answering(.replace, asked: asked))

        #expect(asked.names.isEmpty)
        #expect(try size(top) == 1)
        #expect(copies.map(\.lastPathComponent).sorted() == ["x 2.txt", "x copy.txt"])
    }

    @Test("Undoing a replace restores the original name's letter case")
    func undoKeepsOriginalCase() async throws {
        let source = try dir.file("a/foo.txt", bytes: 1)
        let target = try dir.folder("b")
        try dir.file("b/Foo.txt", bytes: 2)

        _ = try await actions.copy([source], into: target, resolveConflicts: answering(.replace, asked: Recorder()))
        await undo()

        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["Foo.txt"])
    }

    @Test("The remaining count only counts items that will also clash")
    func remainingCountsConflictsOnly() async throws {
        let sources = try ["p", "q", "r"].map { try dir.file("a/\($0).txt") }
        let target = try dir.folder("b")
        try dir.file("b/p.txt")
        try dir.file("b/r.txt")
        var remaining: [Int] = []

        _ = try await actions.copy(sources, into: target) { conflict in
            remaining.append(conflict.remaining)
            return ConflictDecision(resolution: .skip)
        }

        #expect(remaining == [1, 0])
    }

    @Test("If the destination gets taken right after the old item was trashed, undo can still bring it back")
    func racedReplaceStaysUndoable() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        // A copier that finds the name taken by something that appeared meanwhile.
        let racing = FileActions.testing(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))),
            copier: { _, destination, _, _ in
                try Data("raced".utf8).write(to: destination)
                throw CocoaError(.fileWriteFileExists)
            })
        racing.undoManager = undoManager
        let source = try dir.file("a/x.txt", bytes: 1)
        let target = try dir.folder("b")
        try dir.file("b/x.txt", bytes: 2)

        await #expect(throws: (any Error).self) {
            try await racing.copy([source], into: target) { _ in ConflictDecision(resolution: .replace) }
        }

        #expect(try String(contentsOf: target.appending(path: "x.txt"), encoding: .utf8) == "raced")
        #expect(undoManager.canUndo)   // the trashed original is still on record
    }

    @Test("If a folder appears where a replaced folder was, the copy refuses instead of merging into it")
    func racedFolderReplaceDoesNotMerge() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        // A real copy, but a folder appears at the destination just before it starts.
        let racing = FileActions.testing(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))),
            copier: { source, destination, progress, shouldCancel in
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                try Data("other".utf8).write(to: destination.appending(path: "other.txt"))
                try FileCopier.copy(from: source, to: destination, progress: progress, shouldCancel: shouldCancel)
            })
        racing.undoManager = undoManager
        let source = try dir.folder("src/Photos")
        try dir.file("src/Photos/new.jpg")
        let target = try dir.folder("dst")
        try dir.file("dst/Photos/old.jpg")

        await #expect(throws: (any Error).self) {
            try await racing.copy([source], into: target) { _ in ConflictDecision(resolution: .replace) }
        }

        let raced = target.appending(path: "Photos")
        #expect(try FileManager.default.contentsOfDirectory(atPath: raced.path) == ["other.txt"])   // not merged into
        #expect(undoManager.canUndo)   // the trashed original is still on record
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
        let actions = FileActions.testing(
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

    @Test("Closing the window while a conflict is pending skips it, so later operations still run")
    func closingWindowReleasesPrompt() async throws {
        let dir = try TemporaryDirectory()
        let source = try dir.file("a/x.txt", bytes: 1)
        let target = try dir.folder("b")
        let existing = try dir.file("b/x.txt", bytes: 2)
        let defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        let actions = FileActions.testing(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))))
        let model = BrowserModel(start: target, actions: actions, defaults: defaults)
        actions.copyToClipboard([source])

        let pasting = Task { await model.paste() }
        while model.pendingConflict == nil { await Task.yield() }
        model.windowWillClose()
        await pasting.value

        #expect(try Data(contentsOf: existing).count == 2)
        let later = try await actions.copy([source], into: dir.folder("c"))
        #expect(later.count == 1)
    }

    @Test("A paste still queued when the window closes doesn't ask (and doesn't block the queue)")
    func queuedPasteAfterCloseDoesNotAsk() async throws {
        let dir = try TemporaryDirectory()
        let source = try dir.file("a/x.txt", bytes: 1)
        let target = try dir.folder("b")
        let existing = try dir.file("b/x.txt", bytes: 2)
        let defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        let actions = FileActions.testing(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))))
        let model = BrowserModel(start: target, actions: actions, defaults: defaults)
        actions.copyToClipboard([source])

        let first = Task { await model.paste() }
        while model.pendingConflict == nil { await Task.yield() }
        let second = Task { await model.paste() }
        while actions.queuedOperations == 0 { await Task.yield() }
        model.windowWillClose()
        await first.value
        await second.value

        #expect(model.pendingConflict == nil)
        #expect(try Data(contentsOf: existing).count == 2)
    }

    @Test("A replacing item keeps its own name's letter case")
    func replaceKeepsIncomingCase() async throws {
        let dir = try TemporaryDirectory()
        let actions = FileActions.testing(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))))
        let source = try dir.file("a/Foo.txt", bytes: 1)
        let target = try dir.folder("b")
        try dir.file("b/foo.txt", bytes: 2)

        _ = try await actions.copy([source], into: target) { _ in ConflictDecision(resolution: .replace) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["Foo.txt"])
    }
}
