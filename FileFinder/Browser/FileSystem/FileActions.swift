import Foundation
import Observation

enum FileActionError: LocalizedError, Equatable {
    case invalidName
    case nameTaken(String)
    case cannotCopyIntoItself
    case cannotReplaceContainingFolder(String)

    var errorDescription: String? {
        switch self {
        case .invalidName: "That name can't be used. Names can't be empty or contain \"/\"."
        case .nameTaken(let name): "The name \"\(name)\" is already taken. Please choose a different name."
        case .cannotCopyIntoItself: "A folder can't be copied or moved into itself."
        case .cannotReplaceContainingFolder(let name):
            "“\(name)” can't be replaced because it contains the item being moved or copied."
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
}

/// An incoming item whose name is taken by `existing`.
nonisolated struct NameConflict: Identifiable, Sendable, Equatable {
    let id = UUID()
    let source: URL
    let existing: URL
    /// Items of the same batch still to be handled after this one.
    let remaining: Int
}

/// Asks the user about one conflict. `nil` means "keep both" without asking.
typealias ConflictResolver = (NameConflict) async -> ConflictDecision

/// A copy in progress, for the progress bar.
@Observable
final class TransferProgress {
    let title: String
    let totalBytes: Int64
    var completedBytes: Int64 = 0

    init(title: String, totalBytes: Int64) {
        self.title = title
        self.totalBytes = totalBytes
    }

    var fraction: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
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

    init(
        clipboard: FileClipboard = .shared,
        copier: @escaping Copier = { try FileCopier.copy(from: $0, to: $1, progress: $2, shouldCancel: $3) }
    ) {
        self.clipboard = clipboard
        self.copier = copier
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
            let result = await Self.performMoves([FileTransfer(from: url, to: destination)])
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
            let replaced = await Self.performTrash(plan.replacing)
            var result = BatchResult()
            if replaced.error == nil, !plan.transfers.isEmpty {
                let sizes = await Self.sizes(of: plan.transfers.map(\.from))
                let progress = TransferProgress(
                    title: Self.copyTitle(plan.transfers, into: folder), totalBytes: sizes.reduce(0, +))
                self.currentTransfer = progress
                defer { self.currentTransfer = nil }
                result = await Self.performCopies(plan.transfers, copier: self.copier, sizes: sizes) { bytes in
                    Task { @MainActor in progress.completedBytes = bytes }
                }
            }
            self.registerAsOneStep(if: !replaced.done.isEmpty || !result.done.isEmpty) {
                if !replaced.done.isEmpty { self.registerRelocationUndo("Replace", replaced.done) }
                if !result.done.isEmpty {
                    self.registerCopyUndo(CopyRecord(transfers: result.done, fileNumbers: result.fileNumbers))
                }
            }
            if let error = replaced.error ?? result.error { throw error }
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
            let replaced = await Self.performTrash(plan.replacing)
            let result = replaced.error == nil ? await Self.performMoves(plan.transfers) : BatchResult()
            self.registerAsOneStep(if: !replaced.done.isEmpty || !result.done.isEmpty) {
                if !replaced.done.isEmpty { self.registerRelocationUndo("Replace", replaced.done) }
                if !result.done.isEmpty { self.registerRelocationUndo("Move", result.done) }
            }
            if let error = replaced.error ?? result.error { throw error }
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
            let copier = actions.copier
            actions.enqueue {
                let result = await Self.performCopies(record.transfers, copier: copier)
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
        _ plan: [FileTransfer], copier: Copier, sizes: [Int64] = [],
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
            // Never write over, or clean up, something that is already there.
            if fileManager.fileExists(atPath: transfer.to.path) {
                result.error = CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: transfer.to.path])
                continue
            }
            do {
                let offset = base
                try copier(transfer.from, transfer.to, { report?(offset + $0) }, { Task.isCancelled })
                result.done.append(transfer)
                if let number = fileNumber(of: transfer.to) { result.fileNumbers[transfer.to.path] = number }
                base += index < sizes.count ? sizes[index] : 0
                report?(base)
            } catch {
                // The destination didn't exist before, so anything there now is our partial copy,
                // unless the copy failed precisely because something appeared there meanwhile.
                if !isAlreadyExists(error), fileManager.fileExists(atPath: transfer.to.path) {
                    try? fileManager.removeItem(at: transfer.to)
                }
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
    @concurrent private nonisolated static func sizes(of urls: [URL]) async -> [Int64] {
        urls.map { url in
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

    /// Destinations for a batch, asking `resolver` about each name clash in another folder.
    /// Returns the transfers to perform and the existing items they replace.
    static func resolvedPlan(
        _ urls: [URL], into folder: URL, copying: Bool, resolver: ConflictResolver?
    ) async throws -> (transfers: [FileTransfer], replacing: [URL]) {
        var reserved: Set<String> = []
        var transfers: [FileTransfer] = []
        var replacing: [URL] = []
        var remembered: ConflictResolution?

        for (index, source) in urls.enumerated() {
            let sameFolder = isSameFolder(source.deletingLastPathComponent(), folder)
            let candidate = folder.appendingPathComponent(source.lastPathComponent)
            let key = candidate.lastPathComponent.lowercased()
            let clashesInBatch = reserved.contains(key)
            let clashesOnDisk = FileManager.default.fileExists(atPath: candidate.path)

            var resolution = ConflictResolution.keepBoth
            if !sameFolder, clashesOnDisk, !clashesInBatch, let resolver {
                if let remembered {
                    resolution = remembered
                } else {
                    let decision = await resolver(
                        NameConflict(source: source, existing: candidate, remaining: urls.count - index - 1))
                    resolution = decision.resolution
                    if decision.applyToAll { remembered = decision.resolution }
                }
            }

            let destination: URL
            switch resolution {
            case .skip:
                continue
            case .replace:
                let existingPath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
                let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
                if sourcePath.hasPrefix(existingPath + "/") {
                    throw FileActionError.cannotReplaceContainingFolder(candidate.lastPathComponent)
                }
                replacing.append(candidate)
                destination = candidate
            case .keepBoth:
                destination = uniqueDestination(
                    for: source, in: folder, copyStyle: copying && sameFolder, reserved: reserved)
            }
            reserved.insert(destination.lastPathComponent.lowercased())
            transfers.append(FileTransfer(from: source, to: destination))
        }
        return (transfers, replacing)
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
