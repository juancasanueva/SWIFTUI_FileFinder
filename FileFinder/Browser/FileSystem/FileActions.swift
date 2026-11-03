import Foundation
import Observation

enum FileActionError: LocalizedError, Equatable {
    case invalidName
    case nameTaken(String)
    case cannotCopyIntoItself

    var errorDescription: String? {
        switch self {
        case .invalidName: "That name can't be used. Names can't be empty or contain \"/\"."
        case .nameTaken(let name): "The name \"\(name)\" is already taken. Please choose a different name."
        case .cannotCopyIntoItself: "A folder can't be copied or moved into itself."
        }
    }
}

/// One item going from `from` to `to` (a move, a copy, or a trip to the Trash).
nonisolated struct FileTransfer: Equatable, Sendable {
    let from: URL
    let to: URL
    var reversed: FileTransfer { FileTransfer(from: to, to: from) }
}

/// What a batch managed to do before it stopped, and why it stopped.
nonisolated struct BatchResult: Sendable {
    var done: [FileTransfer] = []
    var error: (any Error)?
}

/// Mutating file operations. Disk work runs off the main actor; every completed step registers
/// its inverse on `undoManager`. Undo/redo work runs in the background, one batch at a time, and
/// reports failures through `onBackgroundError`.
@Observable
final class FileActions {
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored let clipboard: FileClipboard
    /// Receives errors from undo/redo work, which has no caller to throw to.
    @ObservationIgnored var onBackgroundError: ((String) -> Void)?
    /// Tail of the serial chain of disk work, so batches never interleave.
    @ObservationIgnored private var lastWork: Task<Void, Never>?

    private var fileManager: FileManager { .default }

    init(clipboard: FileClipboard = .shared) {
        self.clipboard = clipboard
    }

    /// Waits until all queued undo/redo work has finished.
    func waitForPendingWork() async {
        await lastWork?.value
    }

    // MARK: - Rename

    /// Renames in place. Synchronous: a rename never moves data across volumes.
    @discardableResult
    func rename(_ url: URL, to newName: String) throws -> URL {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { throw FileActionError.invalidName }
        let oldName = url.lastPathComponent
        guard name != oldName else { return url }

        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        let isCaseOnlyChange = name.lowercased() == oldName.lowercased()
        if !isCaseOnlyChange, fileManager.fileExists(atPath: destination.path) {
            throw FileActionError.nameTaken(name)
        }
        try fileManager.moveItem(at: url, to: destination)
        registerUndo("Rename") { actions in
            do { try actions.rename(destination, to: oldName) } catch { actions.report(error) }
        }
        return destination
    }

    // MARK: - Copy / Move

    /// Copies items into `folder`, keeping both on name clashes. Returns the created URLs.
    @discardableResult
    func copy(_ urls: [URL], into folder: URL) async throws -> [URL] {
        try Self.rejectNesting(urls, into: folder)
        await waitForPendingWork()
        let plan = Self.plan(urls, into: folder, copying: true)
        let result = await Self.performCopies(plan)
        if !result.done.isEmpty { registerCopyUndo(result.done) }
        if let error = result.error { throw error }
        return result.done.map(\.to)
    }

    /// Moves items into `folder`. Items already in `folder` are skipped. Returns the new URLs.
    @discardableResult
    func move(_ urls: [URL], into folder: URL) async throws -> [URL] {
        try Self.rejectNesting(urls, into: folder)
        await waitForPendingWork()
        let plan = Self.plan(urls.filter { !Self.isSameFolder($0.deletingLastPathComponent(), folder) },
                             into: folder, copying: false)
        let result = await Self.performMoves(plan)
        if !result.done.isEmpty { registerRelocationUndo("Move", result.done) }
        if let error = result.error { throw error }
        return result.done.map(\.to)
    }

    // MARK: - Trash

    func trash(_ urls: [URL]) async throws {
        await waitForPendingWork()
        let result = await Self.performTrash(urls)
        if !result.done.isEmpty { registerRelocationUndo("Move to Trash", result.done) }
        if let error = result.error { throw error }
    }

    // MARK: - Clipboard

    func copyToClipboard(_ urls: [URL]) { clipboard.write(urls, cut: false) }
    func cutToClipboard(_ urls: [URL]) { clipboard.write(urls, cut: true) }
    var canPaste: Bool { clipboard.hasFiles }

    /// Pastes clipboard files into `folder`: moves after a cut (or when `forceMove`, Finder's ⌥⌘V),
    /// copies otherwise.
    @discardableResult
    func paste(into folder: URL, forceMove: Bool = false) async throws -> [URL] {
        let (urls, isCut) = clipboard.read()
        guard !urls.isEmpty else { return [] }
        guard isCut || forceMove else { return try await copy(urls, into: folder) }
        do {
            let moved = try await move(urls, into: folder)
            if !moved.isEmpty { clipboard.write(moved, cut: false) }
            return moved
        } catch {
            // Keep what wasn't moved on the clipboard so the paste can be retried.
            if isCut {
                let remaining = urls.filter { fileManager.fileExists(atPath: $0.path) }
                clipboard.write(remaining, cut: true)
            }
            throw error
        }
    }

    // MARK: - Undo registration

    /// `done` already happened; undoing it moves everything back, and redoing moves it again.
    private func registerRelocationUndo(_ actionName: String, _ done: [FileTransfer]) {
        registerUndo(actionName) { actions in
            let inverse = done.reversed().map(\.reversed)
            actions.registerRelocationUndo(actionName, inverse)
            actions.enqueue { await Self.performMoves(inverse) }
        }
    }

    /// Undoing a copy trashes the copies; redoing it copies the same sources to the same names.
    private func registerCopyUndo(_ copies: [FileTransfer]) {
        registerUndo("Copy") { actions in
            actions.registerRecopyUndo(copies)
            actions.enqueue { await Self.performTrash(copies.map(\.to)) }
        }
    }

    private func registerRecopyUndo(_ copies: [FileTransfer]) {
        registerUndo("Copy") { actions in
            actions.registerCopyUndo(copies)
            actions.enqueue { await Self.performCopies(copies) }
        }
    }

    /// Inverse steps must be registered synchronously inside the undo/redo call so the undo
    /// manager files them on the right stack; only the disk work is deferred.
    private func registerUndo(_ actionName: String, _ handler: @escaping (FileActions) -> Void) {
        guard let undoManager else { return }
        // Registrations made while undoing/redoing are grouped by the undo manager itself.
        let needsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { handler($0) }
        undoManager.setActionName(actionName)
        if needsGroup { undoManager.endUndoGrouping() }
    }

    private func enqueue(_ work: @escaping @Sendable () async -> BatchResult) {
        let previous = lastWork
        lastWork = Task {
            await previous?.value
            let result = await work()
            if let error = result.error { report(error) }
        }
    }

    private func report(_ error: any Error) {
        onBackgroundError?(error.localizedDescription)
    }

    // MARK: - Disk work (off the main actor)

    @concurrent private nonisolated static func performCopies(_ plan: [FileTransfer]) async -> BatchResult {
        let fileManager = FileManager.default
        var result = BatchResult()
        for transfer in plan {
            do {
                try fileManager.copyItem(at: transfer.from, to: transfer.to)
                result.done.append(transfer)
            } catch {
                // Don't leave a half-copied item behind.
                if fileManager.fileExists(atPath: transfer.to.path) {
                    try? fileManager.trashItem(at: transfer.to, resultingItemURL: nil)
                }
                result.error = error
                break
            }
        }
        return result
    }

    @concurrent private nonisolated static func performMoves(_ plan: [FileTransfer]) async -> BatchResult {
        var result = BatchResult()
        for transfer in plan {
            do {
                try FileManager.default.moveItem(at: transfer.from, to: transfer.to)
                result.done.append(transfer)
            } catch {
                result.error = error
                break
            }
        }
        return result
    }

    @concurrent private nonisolated static func performTrash(_ urls: [URL]) async -> BatchResult {
        var result = BatchResult()
        for url in urls {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                if let trashed = resulting as URL? { result.done.append(FileTransfer(from: url, to: trashed)) }
            } catch {
                result.error = error
                break
            }
        }
        return result
    }

    // MARK: - Naming

    /// Destinations for a batch. Names chosen earlier in the batch count as taken, so two items
    /// called "x.txt" from different folders become "x.txt" and "x 2.txt".
    nonisolated static func plan(_ urls: [URL], into folder: URL, copying: Bool) -> [FileTransfer] {
        var reserved: Set<String> = []
        return urls.map { source in
            let copyStyle = copying && isSameFolder(source.deletingLastPathComponent(), folder)
            let destination = uniqueDestination(for: source, in: folder, copyStyle: copyStyle, reserved: reserved)
            reserved.insert(destination.lastPathComponent.lowercased())
            return FileTransfer(from: source, to: destination)
        }
    }

    /// Throws when `folder` is one of `urls` or lies inside one of them.
    nonisolated static func rejectNesting(_ urls: [URL], into folder: URL) throws {
        let target = folder.resolvingSymlinksInPath().standardizedFileURL.path
        for url in urls {
            let source = url.resolvingSymlinksInPath().standardizedFileURL.path
            if target == source || target.hasPrefix(source + "/") {
                throw FileActionError.cannotCopyIntoItself
            }
        }
    }

    nonisolated static func isSameFolder(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Finder naming for clashes: "name copy.ext", "name copy 2.ext" when duplicating in place,
    /// otherwise "name 2.ext", "name 3.ext".
    nonisolated static func uniqueDestination(
        for source: URL, in folder: URL, copyStyle: Bool, reserved: Set<String> = []
    ) -> URL {
        let fileManager = FileManager.default
        func isFree(_ url: URL) -> Bool {
            !reserved.contains(url.lastPathComponent.lowercased()) && !fileManager.fileExists(atPath: url.path)
        }
        let name = source.lastPathComponent
        let candidate = folder.appendingPathComponent(name)
        if !copyStyle, isFree(candidate) { return candidate }

        let ext = source.pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var index = copyStyle ? 1 : 2
        while true {
            let stem = copyStyle
                ? (index == 1 ? "\(base) copy" : "\(base) copy \(index)")
                : "\(base) \(index)"
            let url = folder.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
            if isFree(url) { return url }
            index += 1
        }
    }
}
