import Foundation
import Observation

enum FileActionError: LocalizedError, Equatable {
    case invalidName
    case nameTaken(String)
    case cannotCopyIntoItself
    case cannotReplaceContainingFolder(String)
    case notTheTrash

    var errorDescription: String? {
        switch self {
        case .invalidName: "That name can't be used. Names can't be empty or contain \"/\"."
        case .nameTaken(let name): "The name \"\(name)\" is already taken. Please choose a different name."
        case .cannotCopyIntoItself: "A folder can't be copied or moved into itself."
        case .cannotReplaceContainingFolder(let name):
            "“\(name)” can't be replaced because it contains the item being moved or copied."
        case .notTheTrash: "Only the Trash can be emptied."
        }
    }
}

/// How to handle an item whose name is already taken in the destination folder.
nonisolated enum ConflictResolution: Sendable {
    case keepBoth, replace, skip
}

nonisolated struct ConflictDecision: Sendable, Equatable {
    var resolution: ConflictResolution
    /// Use the same answer for the rest of the batch.
    var applyToAll = false

    /// Give up on every remaining conflict: used when nobody can answer anymore.
    static let skipAll = ConflictDecision(resolution: .skip, applyToAll: true)
}

/// An incoming item whose name is taken by `existing`.
nonisolated struct NameConflict: Identifiable, Sendable, Equatable {
    let id = UUID()
    let source: URL
    let existing: URL
    /// Later items of the same batch whose names clash too.
    let remaining: Int
}

/// Asks the user about one conflict. Operations given no resolver keep both without asking.
typealias ConflictResolver = (NameConflict) async -> ConflictDecision

/// A copy in progress, for the progress bar.
@Observable
final class TransferProgress {
    let title: String
    /// Known once the sources are measured; until then the bar shows "Preparing…".
    var totalBytes: Int64
    var completedBytes: Int64 = 0
    var isMeasuring: Bool

    init(title: String, totalBytes: Int64 = 0, isMeasuring: Bool = false) {
        self.title = title
        self.totalBytes = totalBytes
        self.isMeasuring = isMeasuring
    }

    var fraction: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
    }
}

/// Identity for the undo steps that bring items back out of the Trash.
private final class TrashUndoTarget {}

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
    /// Existing items moved to the Trash because a finished transfer replaced them.
    var trashed: [FileTransfer] = []
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
    /// The undo target of steps that bring items back out of the Trash, so emptying the Trash
    /// can drop exactly those.
    @ObservationIgnored private let trashUndoTarget = TrashUndoTarget()
    /// Cancel handles of queued and running operations, and which one is running.
    @ObservationIgnored private var cancellers: [UUID: () -> Void] = [:]
    @ObservationIgnored private var runningOperation: UUID?

    /// The copy being performed right now, if any.
    private(set) var currentTransfer: TransferProgress?
    /// Operations waiting behind the running one.
    private(set) var queuedOperations = 0

    /// Copies one item, reporting progress and checking for cancellation.
    typealias Copier = @Sendable (
        _ source: URL, _ destination: URL,
        _ progress: @escaping @Sendable (Int64) -> Void, _ shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> Void

    @ObservationIgnored private let copier: Copier
    /// Bytes per item, measured before a copy for the progress bar.
    typealias SizeMeasurer = @Sendable ([URL]) async -> [Int64]
    @ObservationIgnored private let measureSizes: SizeMeasurer
    /// Moves one item to the Trash and returns where it went (`nil` when unknown).
    typealias Trasher = @Sendable (URL) throws -> URL?
    @ObservationIgnored private let trasher: Trasher
    /// The Trash that `trasher` fills and Empty Trash empties. Only paths inside it count as
    /// the Trash; other folders named ".Trash" and other volumes' ".Trashes" don't.
    let trashFolder: URL

    init(
        clipboard: FileClipboard = .shared,
        copier: @escaping Copier = { try FileCopier.copy(from: $0, to: $1, progress: $2, shouldCancel: $3) },
        measureSizes: @escaping SizeMeasurer = { await FileActions.sizes(of: $0) },
        trashFolder: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash"),
        trasher: @escaping Trasher = FileActions.systemTrasher
    ) {
        self.clipboard = clipboard
        self.copier = copier
        self.measureSizes = measureSizes
        self.trashFolder = trashFolder.canonical
        self.trasher = trasher
    }

    /// The system's Move to Trash.
    nonisolated static let systemTrasher: Trasher = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Stops the running operation. Items it already finished stay (and can be undone);
    /// a partly copied item is removed. Queued operations still run.
    func cancelCurrentTransfer() {
        guard let runningOperation else { return }
        cancellers[runningOperation]?()
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
            let result = await Self.performMoves([FileTransfer(from: url, to: destination)], trasher: self.trasher)
            if let error = result.error { throw error }
            self.registerRelocationUndo("Rename", result.done)
            return destination
        }
    }

    // MARK: - Copy / Move

    /// Copies items into `folder`. Name clashes go to `resolveConflicts`; without one, both are
    /// kept. Returns the created URLs.
    @discardableResult
    func copy(
        _ urls: [URL], into folder: URL, resolveConflicts: ConflictResolver? = nil
    ) async throws -> [URL] {
        try Self.rejectNesting(urls, into: folder)
        return try await serialized {
            // Planned inside the queue, so earlier operations' results count as taken names.
            let plan = try await Self.resolvedPlan(urls, into: folder, copying: true, resolver: resolveConflicts)
            try Task.checkCancellation()
            var result = BatchResult()
            if !plan.transfers.isEmpty {
                // Show the bar (and Cancel) before measuring: measuring a huge tree takes a while.
                let progress = TransferProgress(title: Self.copyTitle(plan.transfers, into: folder), isMeasuring: true)
                self.currentTransfer = progress
                defer { self.currentTransfer = nil }
                let sizes = await self.measureSizes(plan.transfers.map(\.from))
                try Task.checkCancellation()
                progress.totalBytes = sizes.reduce(0, +)
                progress.isMeasuring = false
                result = await Self.performCopies(
                    plan.transfers, replacing: plan.replacing, copier: self.copier, trasher: self.trasher, sizes: sizes
                ) { bytes in
                    Task { @MainActor in progress.completedBytes = bytes }
                }
            }
            self.registerAsOneStep(if: !result.done.isEmpty || !result.trashed.isEmpty) {
                if !result.trashed.isEmpty { self.registerRelocationUndo("Replace", result.trashed) }
                if !result.done.isEmpty {
                    self.registerCopyUndo(CopyRecord(transfers: result.done, fileNumbers: result.fileNumbers))
                }
            }
            if let error = result.error { throw error }
            return result.done.map(\.to)
        }
    }

    /// Moves items into `folder`. Items already in `folder` are skipped; name clashes go to
    /// `resolveConflicts` (without one, both are kept). Returns the new URLs.
    @discardableResult
    func move(
        _ urls: [URL], into folder: URL, resolveConflicts: ConflictResolver? = nil
    ) async throws -> [URL] {
        try Self.rejectNesting(urls, into: folder)
        return try await serialized {
            let sources = urls.filter { !Self.isSameFolder($0.deletingLastPathComponent(), folder) }
            let plan = try await Self.resolvedPlan(sources, into: folder, copying: false, resolver: resolveConflicts)
            let result = await Self.performMoves(plan.transfers, replacing: plan.replacing, trasher: self.trasher)
            self.registerAsOneStep(if: !result.done.isEmpty || !result.trashed.isEmpty) {
                if !result.trashed.isEmpty { self.registerRelocationUndo("Replace", result.trashed) }
                if !result.done.isEmpty { self.registerRelocationUndo("Move", result.done) }
            }
            if let error = result.error { throw error }
            return result.done.map(\.to)
        }
    }

    /// Registers several inverses as one undo step; undo runs them in reverse order (so a
    /// replaced item is restored after the transfer that replaced it is reversed). Synchronous
    /// on purpose: an undo group must never stay open across an `await`, or a ⌘Z arriving
    /// meanwhile would hit an open group.
    private func registerAsOneStep(if hasWork: Bool, _ body: () -> Void) {
        // An empty group would still count as an undo step.
        guard hasWork else { return }
        guard let undoManager else { return body() }
        undoManager.beginUndoGrouping()
        body()
        undoManager.endUndoGrouping()
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

    // MARK: - Tidy

    /// Moves each group's files into its kind folder, creating missing folders, as one undo
    /// step. Files no longer where the plan saw them are skipped; a clash keeps both. Undo moves
    /// everything back and trashes the folders this created while they are still empty.
    @discardableResult
    func tidy(_ plan: TidyPlan) async throws -> [URL] {
        try await serialized {
            let fileManager = FileManager.default
            var created: [URL] = []
            var transfers: [FileTransfer] = []
            var setupError: (any Error)?
            for group in plan.groups {
                let sources = group.files.filter {
                    fileManager.fileExists(atPath: $0.path) && Self.isSameFolder($0.deletingLastPathComponent(), plan.folder)
                }
                guard !sources.isEmpty else { continue }
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: group.folder.path, isDirectory: &isDirectory) {
                    guard isDirectory.boolValue else { continue }   // a file took the name since the preview
                } else {
                    do {
                        try await Self.performCreateFolder(group.folder)
                        created.append(group.folder)
                    } catch {
                        setupError = error
                        break
                    }
                }
                transfers += try await Self.resolvedPlan(sources, into: group.folder, copying: false, resolver: nil).transfers
            }
            let result = await Self.performMoves(transfers, trasher: self.trasher)
            // Folders first, so undo (which runs in reverse) moves the files out before checking
            // whether the folders are empty.
            self.registerAsOneStep(if: !created.isEmpty || !result.done.isEmpty) {
                for folder in created { self.registerNewFolderUndo(folder, actionName: "Tidy", reuseExisting: true) }
                if !result.done.isEmpty { self.registerRelocationUndo("Tidy", result.done) }
            }
            if let error = setupError ?? result.error { throw error }
            return result.done.map(\.to)
        }
    }

    // MARK: - Trash

    /// Moves items to the Trash as one undo step named `actionName`.
    func trash(_ urls: [URL], actionName: String = "Move to Trash") async throws {
        try await serialized {
            let result = await Self.performTrash(urls, trasher: self.trasher)
            if !result.done.isEmpty { self.registerRelocationUndo(actionName, result.done) }
            if let error = result.error { throw error }
        }
    }

    /// Drops the undo steps that would bring items back out of the Trash, once emptying it
    /// deleted them; every other undo step (renames, moves, copies…) stays.
    func dropTrashUndo() {
        undoManager?.removeAllActions(withTarget: trashUndoTarget)
    }

    /// Permanently deletes everything in `trash`. Not undoable, so callers must ask first.
    /// Refuses anything but `trashFolder`, and it only when it is a real folder: a link named
    /// ".Trash" would otherwise empty the folder it points to. Once anything was deleted, even when emptying
    /// then failed, the undo steps that would restore items from the Trash are dropped.
    func emptyTrash(_ trash: URL) async throws {
        guard trash.canonical == trashFolder else { throw FileActionError.notTheTrash }
        // Checked inside the queued work, right before deleting: the Trash may change while
        // earlier operations run.
        try await serialized {
            let result = await Self.performEmptyTrash(trash)
            if result.deletedSomething { self.dropTrashUndo() }
            if let error = result.error { throw error }
        }
    }

    /// The folder's device and inode, or `nil` when `url` isn't a real folder. `lstat` never
    /// follows a final link.
    private nonisolated static func realFolderIdentity(_ url: URL) -> (dev_t, ino_t)? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return (info.st_dev, info.st_ino)
    }

    /// Whether anything was deleted, without walking the Trash: a top-level item removed, or
    /// a folder whose removal failed (it deletes its contents one by one and stops at the
    /// first it can't, so part of it may be gone).
    @concurrent private nonisolated static func performEmptyTrash(
        _ trash: URL
    ) async -> (deletedSomething: Bool, error: (any Error)?) {
        guard let identity = realFolderIdentity(trash) else { return (false, FileActionError.notTheTrash) }
        let fileManager = FileManager.default
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: trash.path)
        } catch {
            return (false, error)
        }
        var deletedSomething = false
        var firstError: (any Error)?
        for name in names {
            // Still the same real folder before every deletion, never a link swapped in.
            guard let current = realFolderIdentity(trash), current == identity else {
                return (deletedSomething, FileActionError.notTheTrash)
            }
            let item = trash.appending(path: name)
            do {
                try fileManager.removeItem(at: item)
                deletedSomething = true
            } catch {
                if realFolderIdentity(item) != nil { deletedSomething = true }
                firstError = firstError ?? error
            }
        }
        return (deletedSomething, firstError)
    }

    // MARK: - Clipboard

    func copyToClipboard(_ urls: [URL]) { clipboard.write(urls, cut: false) }
    func cutToClipboard(_ urls: [URL]) { clipboard.write(urls, cut: true) }
    var canPaste: Bool { clipboard.hasFiles }

    /// Pastes clipboard files into `folder`: moves after a cut (or when `forceMove`, Finder's ⌥⌘V),
    /// copies otherwise.
    @discardableResult
    func paste(
        into folder: URL, forceMove: Bool = false, resolveConflicts: ConflictResolver? = nil
    ) async throws -> [URL] {
        let (urls, isCut) = clipboard.read()
        let stamp = clipboard.changeCount
        guard !urls.isEmpty else { return [] }
        guard isCut || forceMove else { return try await copy(urls, into: folder, resolveConflicts: resolveConflicts) }
        // A long move may finish after the user put something else on the clipboard;
        // only touch the clipboard if it still holds what was pasted.
        let clipboardUnchanged = { self.clipboard.changeCount == stamp }
        do {
            let moved = try await move(urls, into: folder, resolveConflicts: resolveConflicts)
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
        // Undoing a trip into the Trash brings items out of it; undoing a move out of it puts
        // them back, and then its redo is the step that brings them out.
        let restoresFromTrash: Bool? =
            if done.contains(where: { self.isInTrash($0.to) }) { true }
            else if done.contains(where: { self.isInTrash($0.from) }) { false }
            else { nil }
        registerRelocationUndo(actionName, RelocationRecord(transfers: done), restoresFromTrash: restoresFromTrash)
    }

    /// Whether `url` is inside `trashFolder`, the Trash that Empty Trash empties; another
    /// folder named ".Trash" or another volume's `.Trashes` isn't emptied, so its steps keep working.
    private func isInTrash(_ url: URL) -> Bool {
        url.canonical.path.hasPrefix(trashFolder.path + "/")
    }

    /// Undo and redo hand each other a record of what their disk work really moved, so a step
    /// that stopped partway is reversed only as far as it got. `restoresFromTrash` is `nil` for
    /// steps unrelated to the Trash; for Trash moves it says whether this entry brings items
    /// back out of it (then emptying the Trash breaks it, see `dropTrashUndo`) or puts them in.
    private func registerRelocationUndo(_ actionName: String, _ record: RelocationRecord, restoresFromTrash: Bool?) {
        registerUndo(actionName, target: restoresFromTrash == true ? trashUndoTarget : self) { actions in
            let trasher = actions.trasher
            let reverse = RelocationRecord(transfers: [])
            actions.registerRelocationUndo(actionName, reverse, restoresFromTrash: restoresFromTrash.map { !$0 })
            actions.enqueue {
                // Read the record when the work runs: the step before it has finished by then.
                let plan = record.transfers.reversed().map(\.reversed)
                let result = await Self.performMoves(plan, stopOnError: false, trasher: trasher)
                reverse.transfers = result.done
                return result
            }
        }
    }

    /// Undoing a copy trashes the copies that are still the files it created.
    private func registerCopyUndo(_ record: CopyRecord) {
        registerUndo("Copy") { actions in
            actions.registerRecopyUndo(record)
            let trasher = actions.trasher
            actions.enqueue {
                // Read the record when the work runs: a queued redo may have just updated it.
                let result = await Self.performTrashCopies(record.transfers, fileNumbers: record.fileNumbers, trasher: trasher)
                record.fileNumbers = [:]
                return result
            }
        }
    }

    /// Redoing a copy copies the same sources to the same names, skipping names now taken.
    private func registerRecopyUndo(_ record: CopyRecord) {
        // Redoing copies the sources again: impossible once they are emptied from the Trash.
        let fromTrash = record.transfers.contains { self.isInTrash($0.from) }
        registerUndo("Copy", target: fromTrash ? trashUndoTarget : self) { actions in
            actions.registerCopyUndo(record)
            let copier = actions.copier, trasher = actions.trasher
            actions.enqueue {
                let result = await Self.performCopies(record.transfers, copier: copier, trasher: trasher)
                record.fileNumbers = result.fileNumbers
                return result
            }
        }
    }

    /// Undoing New Folder trashes the folder, but only while it is still empty. With
    /// `reuseExisting`, redo accepts a folder that is still there (Tidy: undo left it because
    /// something else was put in it) instead of reporting it.
    private func registerNewFolderUndo(_ url: URL, actionName: String = "New Folder", reuseExisting: Bool = false) {
        registerUndo(actionName) { actions in
            actions.registerRecreateFolderUndo(url, actionName: actionName, reuseExisting: reuseExisting)
            let trasher = actions.trasher
            actions.enqueue { await Self.performTrashIfEmpty(url, trasher: trasher) }
        }
    }

    private func registerRecreateFolderUndo(_ url: URL, actionName: String, reuseExisting: Bool) {
        registerUndo(actionName) { actions in
            actions.registerNewFolderUndo(url, actionName: actionName, reuseExisting: reuseExisting)
            actions.enqueue {
                do {
                    var isDirectory: ObjCBool = false
                    if reuseExisting, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                       isDirectory.boolValue {
                        return BatchResult()
                    }
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
    private func registerUndo(
        _ actionName: String, target: AnyObject? = nil, _ handler: @escaping (FileActions) -> Void
    ) {
        guard let undoManager else { return }
        // Registrations made while undoing/redoing are grouped by the undo manager itself.
        let needsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: target ?? self) { [weak self] _ in
            if let self { handler(self) }
        }
        undoManager.setActionName(actionName)
        if needsGroup { undoManager.endUndoGrouping() }
    }

    /// Runs `operation` after everything already queued, and returns its result.
    private func serialized<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = lastWork
        let id = UUID()
        let task = Task<T, any Error> {
            await previous?.value
            self.runningOperation = id
            self.updateQueueCount()
            defer {
                self.cancellers[id] = nil
                self.runningOperation = nil
                self.updateQueueCount()
            }
            return try await operation()
        }
        cancellers[id] = { task.cancel() }
        updateQueueCount()
        lastWork = Task { _ = try? await task.value }
        return try await task.value
    }

    private func updateQueueCount() {
        queuedOperations = cancellers.count - (runningOperation == nil ? 0 : 1)
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

    /// `sizes` (bytes per item, same order as `plan`) and `report` drive the progress bar.
    @concurrent private nonisolated static func performCopies(
        _ plan: [FileTransfer], replacing: [URL?] = [], copier: Copier, trasher: Trasher, sizes: [Int64] = [],
        report: (@Sendable (Int64) -> Void)? = nil
    ) async -> BatchResult {
        let fileManager = FileManager.default
        var result = BatchResult()
        var base: Int64 = 0
        for (index, transfer) in plan.enumerated() {
            if Task.isCancelled {
                result.error = CancellationError()
                break
            }
            // Replace one item at a time, so a failure never leaves earlier replaced items gone.
            let existing = index < replacing.count ? replacing[index] : nil
            var trashed: FileTransfer?
            if let existing {
                do {
                    trashed = try trashItem(existing, trasher: trasher)
                } catch {
                    result.error = error
                    break
                }
            }
            // Put the replaced item back; if that's impossible (its place got taken), keep it on
            // record so undo can still try and report.
            func restoreReplaced() {
                guard let trashed else { return }
                if (try? fileManager.moveItem(at: trashed.to, to: trashed.from)) == nil {
                    result.trashed.append(trashed)
                }
            }
            // Never write over, merge into, or clean up something that is already there. When
            // replacing, the place should be free now; if something took it, put the original back.
            if fileManager.fileExists(atPath: transfer.to.path) {
                result.error = CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: transfer.to.path])
                guard existing != nil else { continue }
                restoreReplaced()
                break
            }
            do {
                let offset = base
                try copier(transfer.from, transfer.to, { report?(offset + $0) }, { Task.isCancelled })
                result.done.append(transfer)
                if let trashed { result.trashed.append(trashed) }
                if let number = fileNumber(of: transfer.to) { result.fileNumbers[transfer.to.path] = number }
                base += index < sizes.count ? sizes[index] : 0
                report?(base)
            } catch {
                // The destination didn't exist before, so anything there now is our partial copy,
                // unless the copy failed precisely because something appeared there meanwhile.
                if !isAlreadyExists(error), fileManager.fileExists(atPath: transfer.to.path) {
                    try? fileManager.removeItem(at: transfer.to)
                }
                restoreReplaced()
                result.error = Task.isCancelled || error is CancellationError ? CancellationError() : error
                break
            }
        }
        return result
    }

    private nonisolated static func isAlreadyExists(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EEXIST))
            || (nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileWriteFileExists.rawValue)
    }

    /// Bytes per item: logical size for files, the whole tree for folders.
    @concurrent nonisolated static func sizes(of urls: [URL]) async -> [Int64] {
        urls.map { url in
            if Task.isCancelled { return 0 }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { return (try? FolderSizeCalculator.measure(url).totalBytes) ?? 0 }
            return Int64(values?.fileSize ?? 0)
        }
    }

    private static func copyTitle(_ plan: [FileTransfer], into folder: URL) -> String {
        let target = folder.lastPathComponent
        if plan.count == 1 { return "Copying “\(plan[0].from.lastPathComponent)” to “\(target)”" }
        return "Copying \(plan.count) items to “\(target)”"
    }

    /// Trashes copies, skipping any that were replaced by a different file since they were made.
    @concurrent private nonisolated static func performTrashCopies(
        _ copies: [FileTransfer], fileNumbers: [String: Int], trasher: Trasher
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
                _ = try trasher(copy.to)
                result.done.append(copy)
            } catch {
                result.error = error
            }
        }
        return result
    }

    /// Undo/redo passes `stopOnError: false` to put back as much as possible.
    @concurrent private nonisolated static func performMoves(
        _ plan: [FileTransfer], replacing: [URL?] = [], stopOnError: Bool = true, trasher: Trasher
    ) async -> BatchResult {
        let fileManager = FileManager.default
        var result = BatchResult()
        for (index, transfer) in plan.enumerated() {
            let existing = index < replacing.count ? replacing[index] : nil
            var trashed: FileTransfer?
            do {
                if let existing { trashed = try trashItem(existing, trasher: trasher) }
                try fileManager.moveItem(at: transfer.from, to: transfer.to)
                result.done.append(transfer)
                if let trashed { result.trashed.append(trashed) }
            } catch {
                // Put back the item this move was going to replace; if its place got taken,
                // keep it on record so undo can still try.
                if let trashed, (try? fileManager.moveItem(at: trashed.to, to: trashed.from)) == nil {
                    result.trashed.append(trashed)
                }
                result.error = error
                if stopOnError { break }
            }
        }
        return result
    }

    /// Moves one item to the Trash and returns where it went. Throws if the Trash doesn't say
    /// where, since the item could then never be put back.
    private nonisolated static func trashItem(_ url: URL, trasher: Trasher) throws -> FileTransfer {
        guard let trashed = try trasher(url) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: url.path,
                NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” went to the Trash, but its new location is unknown, so nothing else was done.",
            ])
        }
        return FileTransfer(from: url, to: trashed)
    }

    @concurrent private nonisolated static func performTrash(_ urls: [URL], trasher: Trasher) async -> BatchResult {
        var result = BatchResult()
        for url in urls {
            do {
                if let trashed = try trasher(url) { result.done.append(FileTransfer(from: url, to: trashed)) }
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

    @concurrent private nonisolated static func performTrashIfEmpty(_ url: URL, trasher: Trasher) async -> BatchResult {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        // Finder drops a .DS_Store into folders it shows; that alone doesn't count as content.
        guard contents.allSatisfy({ $0 == ".DS_Store" }) else {
            return BatchResult(error: FolderNotEmptyError(name: url.lastPathComponent))
        }
        do {
            _ = try trasher(url)
            return BatchResult()
        } catch {
            return BatchResult(error: error)
        }
    }

    private nonisolated static func fileNumber(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.intValue
    }

    // MARK: - Naming

    /// Destinations for a batch, asking `resolver` about each name clash in another folder.
    /// Returns the transfers and, per transfer, the existing item it replaces (if any).
    static func resolvedPlan(
        _ urls: [URL], into folder: URL, copying: Bool, resolver: ConflictResolver?
    ) async throws -> (transfers: [FileTransfer], replacing: [URL?]) {
        func normalized(_ url: URL) -> String { comparablePath(url).lowercased() }
        let batchPaths = Set(urls.map(normalized))
        /// The item already on disk under `name` (in its real letter case), unless it is
        /// itself one of the items being transferred.
        func existingItem(named name: String) -> URL? {
            let candidate = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: candidate.path),
                  !batchPaths.contains(normalized(candidate)) else { return nil }
            // Prefer the exact name: on a case-sensitive volume "Photos" and "photos" are different.
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let realName = entries.contains(name)
                ? name
                : entries.first { $0.lowercased() == name.lowercased() } ?? name
            return folder.appendingPathComponent(realName)
        }
        let clashes: [URL?] = urls.map { source in
            isSameFolder(source.deletingLastPathComponent(), folder) ? nil : existingItem(named: source.lastPathComponent)
        }

        var reserved: Set<String> = []
        var transfers: [FileTransfer] = []
        var replacing: [URL?] = []
        var remembered: ConflictResolution?

        for (index, source) in urls.enumerated() {
            let sameFolder = isSameFolder(source.deletingLastPathComponent(), folder)
            let key = source.lastPathComponent.lowercased()

            var resolution = ConflictResolution.keepBoth
            var existing: URL?
            if let clash = clashes[index], !reserved.contains(key), let resolver {
                existing = clash
                if let remembered {
                    resolution = remembered
                } else {
                    let later = clashes[(index + 1)...].compactMap { $0 }.count
                    let decision = await resolver(NameConflict(source: source, existing: clash, remaining: later))
                    resolution = decision.resolution
                    if decision.applyToAll { remembered = decision.resolution }
                }
            }

            let destination: URL
            switch resolution {
            case .skip:
                continue
            case .replace:
                guard let existing else { continue }
                if normalized(source).hasPrefix(normalized(existing) + "/") {
                    throw FileActionError.cannotReplaceContainingFolder(existing.lastPathComponent)
                }
                // The incoming item keeps its own name (and letter case), like Finder.
                destination = folder.appendingPathComponent(source.lastPathComponent)
                replacing.append(existing)
            case .keepBoth:
                destination = uniqueDestination(
                    for: source, in: folder, copyStyle: copying && sameFolder, reserved: reserved)
                replacing.append(nil)
            }
            reserved.insert(destination.lastPathComponent.lowercased())
            transfers.append(FileTransfer(from: source, to: destination))
        }
        return (transfers, replacing)
    }

    /// The one path form used for comparisons: symlinks resolved, standardized.
    nonisolated static func comparablePath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Throws when `folder` is one of `urls` or lies inside one of them.
    nonisolated static func rejectNesting(_ urls: [URL], into folder: URL) throws {
        let target = comparablePath(folder)
        for url in urls {
            let source = comparablePath(url)
            if target == source || target.hasPrefix(source + "/") {
                throw FileActionError.cannotCopyIntoItself
            }
        }
    }

    nonisolated static func isSameFolder(_ a: URL, _ b: URL) -> Bool {
        comparablePath(a) == comparablePath(b)
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
