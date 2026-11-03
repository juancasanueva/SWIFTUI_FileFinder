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
    /// File number (inode) of each created copy, keyed by path, to recognize it later.
    var fileNumbers: [String: Int] = [:]
}

/// Copies made by one copy action. Undo and redo share it, so undo only trashes items that are
/// still the very files this action created.
private final class CopyRecord {
    let transfers: [FileTransfer]
    var fileNumbers: [String: Int]

    init(transfers: [FileTransfer], fileNumbers: [String: Int]) {
        self.transfers = transfers
        self.fileNumbers = fileNumbers
    }
}

/// Items one move, rename or trash step actually relocated.
private final class RelocationRecord {
    var transfers: [FileTransfer]
    init(transfers: [FileTransfer]) { self.transfers = transfers }
}

nonisolated struct FolderNotEmptyError: LocalizedError {
    let name: String
    var errorDescription: String? {
        "“\(name)” isn't empty anymore, so it was left where it is."
    }
}

nonisolated struct CopyChangedError: LocalizedError {
    let name: String
    var errorDescription: String? {
        "“\(name)” was replaced after it was copied, so it was left where it is."
    }
}

/// Mutating file operations. Disk work runs off the main actor, and every operation, including
/// undo and redo work, runs on one serial queue so batches never interleave. Each completed step
/// registers its inverse on `undoManager`; failures of undo/redo work go to `onBackgroundError`.
@Observable
final class FileActions {
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored let clipboard: FileClipboard
    /// Receives errors from undo/redo work, which has no caller to throw to.
    @ObservationIgnored var onBackgroundError: ((String) -> Void)?
    /// Tail of the serial queue of disk work.
    @ObservationIgnored private var lastWork: Task<Void, Never>?

    init(clipboard: FileClipboard = .shared) {
        self.clipboard = clipboard
    }

    /// Waits until all queued work has finished.
    func waitForPendingWork() async {
        await lastWork?.value
    }

    // MARK: - Rename

    @discardableResult
    func rename(_ url: URL, to newName: String) async throws -> URL {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { throw FileActionError.invalidName }
        let oldName = url.lastPathComponent
        guard name != oldName else { return url }

        return try await serialized {
            let destination = url.deletingLastPathComponent().appendingPathComponent(name)
            let isCaseOnlyChange = name.lowercased() == oldName.lowercased()
            if !isCaseOnlyChange, FileManager.default.fileExists(atPath: destination.path) {
                throw FileActionError.nameTaken(name)
            }
            let result = await Self.performMoves([FileTransfer(from: url, to: destination)])
            if let error = result.error { throw error }
            self.registerRelocationUndo("Rename", result.done)
            return destination
        }
    }

    // MARK: - Copy / Move

    /// Copies items into `folder`, keeping both on name clashes. Returns the created URLs.
    @discardableResult
    func copy(_ urls: [URL], into folder: URL) async throws -> [URL] {
        try Self.rejectNesting(urls, into: folder)
        return try await serialized {
            // Planned inside the queue, so earlier operations' results count as taken names.
            let plan = Self.plan(urls, into: folder, copying: true)
            let result = await Self.performCopies(plan)
            if !result.done.isEmpty {
                self.registerCopyUndo(CopyRecord(transfers: result.done, fileNumbers: result.fileNumbers))
            }
            if let error = result.error { throw error }
            return result.done.map(\.to)
        }
    }

    /// Moves items into `folder`. Items already in `folder` are skipped. Returns the new URLs.
    @discardableResult
    func move(_ urls: [URL], into folder: URL) async throws -> [URL] {
        try Self.rejectNesting(urls, into: folder)
        return try await serialized {
            let sources = urls.filter { !Self.isSameFolder($0.deletingLastPathComponent(), folder) }
            let result = await Self.performMoves(Self.plan(sources, into: folder, copying: false))
            if !result.done.isEmpty { self.registerRelocationUndo("Move", result.done) }
            if let error = result.error { throw error }
            return result.done.map(\.to)
        }
    }

    // MARK: - New folder

    /// Creates "untitled folder" ("untitled folder 2", …) in `folder`, like Finder's ⇧⌘N.
    @discardableResult
    func createFolder(in folder: URL) async throws -> URL {
        try await serialized {
            let url = Self.uniqueDestination(
                for: folder.appendingPathComponent("untitled folder"), in: folder, copyStyle: false)
            try await Self.performCreateFolder(url)
            self.registerNewFolderUndo(url)
            return url
        }
    }

    // MARK: - Trash

    func trash(_ urls: [URL]) async throws {
        try await serialized {
            let result = await Self.performTrash(urls)
            if !result.done.isEmpty { self.registerRelocationUndo("Move to Trash", result.done) }
            if let error = result.error { throw error }
        }
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
        let stamp = clipboard.changeCount
        guard !urls.isEmpty else { return [] }
        guard isCut || forceMove else { return try await copy(urls, into: folder) }
        // A long move may finish after the user put something else on the clipboard;
        // only touch the clipboard if it still holds what was pasted.
        let clipboardUnchanged = { self.clipboard.changeCount == stamp }
        do {
            let moved = try await move(urls, into: folder)
            if !moved.isEmpty, clipboardUnchanged() { clipboard.write(moved, cut: false) }
            return moved
        } catch {
            // Keep what wasn't moved on the clipboard so the paste can be retried.
            if isCut, clipboardUnchanged() {
                let remaining = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
                clipboard.write(remaining, cut: true)
            }
            throw error
        }
    }

    // MARK: - Undo registration

    /// `done` already happened; undoing it moves those items back.
    private func registerRelocationUndo(_ actionName: String, _ done: [FileTransfer]) {
        registerRelocationUndo(actionName, RelocationRecord(transfers: done))
    }

    /// Undo and redo hand each other a record of what their disk work really moved, so a step
    /// that stopped partway is reversed only as far as it got.
    private func registerRelocationUndo(_ actionName: String, _ record: RelocationRecord) {
        registerUndo(actionName) { actions in
            let reverse = RelocationRecord(transfers: [])
            actions.registerRelocationUndo(actionName, reverse)
            actions.enqueue {
                // Read the record when the work runs: the step before it has finished by then.
                let plan = record.transfers.reversed().map(\.reversed)
                let result = await Self.performMoves(plan, stopOnError: false)
                reverse.transfers = result.done
                return result
            }
        }
    }

    /// Undoing a copy trashes the copies that are still the files it created.
    private func registerCopyUndo(_ record: CopyRecord) {
        registerUndo("Copy") { actions in
            actions.registerRecopyUndo(record)
            actions.enqueue {
                // Read the record when the work runs: a queued redo may have just updated it.
                let result = await Self.performTrashCopies(record.transfers, fileNumbers: record.fileNumbers)
                record.fileNumbers = [:]
                return result
            }
        }
    }

    /// Redoing a copy copies the same sources to the same names, skipping names now taken.
    private func registerRecopyUndo(_ record: CopyRecord) {
        registerUndo("Copy") { actions in
            actions.registerCopyUndo(record)
            actions.enqueue {
                let result = await Self.performCopies(record.transfers)
                record.fileNumbers = result.fileNumbers
                return result
            }
        }
    }

    /// Undoing New Folder trashes the folder, but only while it is still empty.
    private func registerNewFolderUndo(_ url: URL) {
        registerUndo("New Folder") { actions in
            actions.registerRecreateFolderUndo(url)
            actions.enqueue { await Self.performTrashIfEmpty(url) }
        }
    }

    private func registerRecreateFolderUndo(_ url: URL) {
        registerUndo("New Folder") { actions in
            actions.registerNewFolderUndo(url)
            actions.enqueue {
                do {
                    try await Self.performCreateFolder(url)
                    return BatchResult()
                } catch {
                    return BatchResult(error: error)
                }
            }
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

    /// Runs `operation` after everything already queued, and returns its result.
    private func serialized<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = lastWork
        let task = Task<T, any Error> {
            await previous?.value
            return try await operation()
        }
        lastWork = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Queues undo/redo work, which has no caller, and reports its failure.
    private func enqueue(_ work: @escaping () async -> BatchResult) {
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
            // Never write over, or clean up, something that is already there.
            if fileManager.fileExists(atPath: transfer.to.path) {
                result.error = CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: transfer.to.path])
                continue
            }
            do {
                try fileManager.copyItem(at: transfer.from, to: transfer.to)
                result.done.append(transfer)
                if let number = fileNumber(of: transfer.to) { result.fileNumbers[transfer.to.path] = number }
            } catch {
                // The destination didn't exist before, so anything there now is our partial copy.
                if fileManager.fileExists(atPath: transfer.to.path) {
                    try? fileManager.trashItem(at: transfer.to, resultingItemURL: nil)
                }
                result.error = error
                break
            }
        }
        return result
    }

    /// Trashes copies, skipping any that were replaced by a different file since they were made.
    @concurrent private nonisolated static func performTrashCopies(
        _ copies: [FileTransfer], fileNumbers: [String: Int]
    ) async -> BatchResult {
        var result = BatchResult()
        for copy in copies {
            guard let expected = fileNumbers[copy.to.path] else { continue }
            guard fileNumber(of: copy.to) == expected else {
                if FileManager.default.fileExists(atPath: copy.to.path) {
                    result.error = CopyChangedError(name: copy.to.lastPathComponent)
                }
                continue
            }
            do {
                try FileManager.default.trashItem(at: copy.to, resultingItemURL: nil)
                result.done.append(copy)
            } catch {
                result.error = error
            }
        }
        return result
    }

    /// Undo/redo passes `stopOnError: false` to put back as much as possible.
    @concurrent private nonisolated static func performMoves(
        _ plan: [FileTransfer], stopOnError: Bool = true
    ) async -> BatchResult {
        var result = BatchResult()
        for transfer in plan {
            do {
                try FileManager.default.moveItem(at: transfer.from, to: transfer.to)
                result.done.append(transfer)
            } catch {
                result.error = error
                if stopOnError { break }
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

    @concurrent private nonisolated static func performCreateFolder(_ url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    @concurrent private nonisolated static func performTrashIfEmpty(_ url: URL) async -> BatchResult {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        // Finder drops a .DS_Store into folders it shows; that alone doesn't count as content.
        guard contents.allSatisfy({ $0 == ".DS_Store" }) else {
            return BatchResult(error: FolderNotEmptyError(name: url.lastPathComponent))
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return BatchResult()
        } catch {
            return BatchResult(error: error)
        }
    }

    private nonisolated static func fileNumber(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.intValue
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
