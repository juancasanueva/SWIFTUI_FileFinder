import AppKit
import Foundation
import Testing
@testable import FileFinder

@Suite("File copier")
struct FileCopierTests {
    @Test("Copies a file and reports progress up to its size")
    func copiesFileWithProgress() throws {
        let dir = try TemporaryDirectory()
        let source = try dir.file("big.bin", bytes: 8_000_000)
        let destination = dir.url.appending(path: "copy.bin")
        let reports = Reports()

        try FileCopier.copy(from: source, to: destination, allowClone: false,
                            progress: { reports.append($0) }, shouldCancel: { false })

        #expect(try Data(contentsOf: destination).count == 8_000_000)
        #expect(reports.values == reports.values.sorted())
        #expect((reports.values.last ?? 0) == 8_000_000)
    }

    @Test("Copies a folder recursively")
    func copiesFolder() throws {
        let dir = try TemporaryDirectory()
        let source = try dir.folder("Album")
        try dir.file("Album/a.jpg", bytes: 10)
        try dir.file("Album/inner/b.jpg", bytes: 20)
        let destination = dir.url.appending(path: "Album copy")

        try FileCopier.copy(from: source, to: destination, progress: { _ in }, shouldCancel: { false })

        #expect(try Data(contentsOf: destination.appending(path: "inner/b.jpg")).count == 20)
    }

    @Test("Refuses to write over an existing item")
    func refusesExisting() throws {
        let dir = try TemporaryDirectory()
        let source = try dir.file("a.txt", bytes: 1)
        let existing = try dir.file("b.txt", bytes: 2)

        #expect(throws: (any Error).self) {
            try FileCopier.copy(from: source, to: existing, progress: { _ in }, shouldCancel: { false })
        }
        #expect(try Data(contentsOf: existing).count == 2)
    }

    @Test("Refuses to copy a folder onto an existing folder instead of nesting it inside")
    func refusesExistingFolder() throws {
        let dir = try TemporaryDirectory()
        let source = try dir.folder("src/Photos")
        try dir.file("src/Photos/new.jpg")
        let existing = try dir.folder("dst/Photos")
        try dir.file("dst/Photos/mine.jpg")

        #expect(throws: (any Error).self) {
            try FileCopier.copy(from: source, to: existing, progress: { _ in }, shouldCancel: { false })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing.path) == ["mine.jpg"])
    }

    @Test("Refuses to copy a file onto an existing folder")
    func refusesFileOntoFolder() throws {
        let dir = try TemporaryDirectory()
        let source = try dir.file("a.txt")
        let existing = try dir.folder("b")

        #expect(throws: (any Error).self) {
            try FileCopier.copy(from: source, to: existing, progress: { _ in }, shouldCancel: { false })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing.path).isEmpty)
    }

    @Test("Cancelling mid-copy stops with a cancellation error")
    func cancelsMidCopy() throws {
        let dir = try TemporaryDirectory()
        let source = try dir.file("big.bin", bytes: 64_000_000)
        let destination = dir.url.appending(path: "copy.bin")
        let reports = Reports()

        #expect(throws: CancellationError.self) {
            try FileCopier.copy(from: source, to: destination, allowClone: false,
                                progress: { reports.append($0) }, shouldCancel: { !reports.values.isEmpty })
        }
    }
}

/// Thread-safe list of progress values.
final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []
    var values: [Int64] { lock.withLock { storage } }
    func append(_ value: Int64) { lock.withLock { storage.append(value) } }
}

@MainActor
@Suite("Transfer queue")
struct TransferQueueTests {
    let dir: TemporaryDirectory

    init() throws { dir = try TemporaryDirectory() }

    /// A copier that copies slowly in steps, so a test can watch and cancel it.
    private static let slowCopier: FileActions.Copier = { source, destination, progress, shouldCancel in
        let size = Int64((try? Data(contentsOf: source).count) ?? 0)
        for step in 1...20 {
            if shouldCancel() { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.02)
            progress(size * Int64(step) / 20)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func makeActions(copier: @escaping FileActions.Copier = slowCopier) -> FileActions {
        FileActions.testing(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))),
            copier: copier)
    }

    @Test("A running copy exposes its title and total size, and clears when done")
    func progressIsExposed() async throws {
        let source = try dir.file("a/x.bin", bytes: 1000)
        let target = try dir.folder("b")
        let actions = makeActions()

        let copying = Task { try await actions.copy([source], into: target) }
        while actions.currentTransfer == nil || actions.currentTransfer?.isMeasuring == true { await Task.yield() }
        #expect(actions.currentTransfer?.totalBytes == 1000)
        #expect(actions.currentTransfer?.title == "Copying “x.bin” to “b”")

        _ = try await copying.value
        #expect(actions.currentTransfer == nil)
    }

    @Test("Cancel stops the running copy, leaves no partial item, and registers no undo")
    func cancelStopsCopy() async throws {
        let source = try dir.file("a/x.bin", bytes: 1000)
        let target = try dir.folder("b")
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let actions = makeActions()
        actions.undoManager = undoManager

        let copying = Task { try await actions.copy([source], into: target) }
        while actions.currentTransfer == nil { await Task.yield() }
        actions.cancelCurrentTransfer()

        await #expect(throws: CancellationError.self) { try await copying.value }
        #expect(!FileManager.default.fileExists(atPath: target.appending(path: "x.bin").path))
        #expect(!undoManager.canUndo)
        #expect(actions.currentTransfer == nil)
    }

    @Test("Cancel only stops the running copy; queued ones still run")
    func cancelLeavesQueue() async throws {
        let first = try dir.file("a/one.bin", bytes: 1000)
        let second = try dir.file("a/two.bin", bytes: 1000)
        let target = try dir.folder("b")
        let actions = makeActions()

        let running = Task { try await actions.copy([first], into: target) }
        while actions.currentTransfer == nil { await Task.yield() }
        let queued = Task { try await actions.copy([second], into: target) }
        while actions.queuedOperations == 0 { await Task.yield() }
        actions.cancelCurrentTransfer()

        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(try await queued.value.map(\.lastPathComponent) == ["two.bin"])
    }

    @Test("Cancel works while sizes are still being measured, before anything is copied",
          .timeLimit(.minutes(1)))
    func cancelDuringMeasuring() async throws {
        let source = try dir.folder("a/Huge")
        try dir.file("a/Huge/x.bin", bytes: 10)
        let target = try dir.folder("b")
        let copierRan = Flag()
        let actions = FileActions.testing(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))),
            copier: { _, _, _, _ in copierRan.set() },
            measureSizes: { urls in
                try? await Task.sleep(for: .seconds(30))   // a very large tree
                return urls.map { _ in 0 }
            })

        let copying = Task { try await actions.copy([source], into: target) }
        while actions.currentTransfer == nil { await Task.yield() }
        #expect(actions.currentTransfer?.isMeasuring == true)
        actions.cancelCurrentTransfer()

        await #expect(throws: CancellationError.self) { try await copying.value }
        #expect(!copierRan.value)
    }

    @Test("A cancelled paste doesn't raise an error alert")
    func cancelIsQuiet() async throws {
        let source = try dir.file("a/x.bin", bytes: 1000)
        let target = try dir.folder("b")
        let actions = makeActions()
        let defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        let model = BrowserModel(start: target, actions: actions, defaults: defaults)
        actions.copyToClipboard([source])

        let pasting = Task { await model.paste() }
        while actions.currentTransfer == nil { await Task.yield() }
        actions.cancelCurrentTransfer()
        await pasting.value

        #expect(model.alertMessage == nil)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.withLock { storage } }
    func set() { lock.withLock { storage = true } }
}
