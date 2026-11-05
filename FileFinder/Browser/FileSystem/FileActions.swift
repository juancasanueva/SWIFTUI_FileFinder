import Foundation
import Observation

enum FileActionError: LocalizedError, Equatable {
    case invalidName
    case nameTaken(String)
    case cannotCopyIntoItself
    case cannotReplaceContainingFolder(String)
    case notTheTrash
    case movedWhileEmptying(String)

    var errorDescription: String? {
        switch self {
        case .invalidName: "That name can't be used. Names can't be empty or contain \"/\"."
        case .nameTaken(let name): "The name \"\(name)\" is already taken. Please choose a different name."
        case .cannotCopyIntoItself: "A folder can't be copied or moved into itself."
        case .cannotReplaceContainingFolder(let name):
            "“\(name)” can't be replaced because it contains the item being moved or copied."
        case .notTheTrash: "Only the Trash can be emptied."
        case .movedWhileEmptying(let name): "“\(name)” was moved while the Trash was being emptied, so what was left of it was kept."
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

/// Identity for the undo steps that need items in the Trash, which emptying it deletes.
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
    /// The undo target of steps that need items in the Trash (bringing them back out, renaming
    /// them, trashing a copy made there), so emptying the Trash can drop exactly those.
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

    @ObservationIgnored nonisolated private let copier: Copier
    /// Bytes per item, measured before a copy for the progress bar.
    typealias SizeMeasurer = @Sendable ([URL]) async -> [Int64]
    @ObservationIgnored private let measureSizes: SizeMeasurer
    /// Moves one item to the Trash and returns where it went (`nil` when unknown).
    typealias Trasher = @Sendable (URL) throws -> URL?
    @ObservationIgnored nonisolated private let trasher: Trasher
    /// The Trash that `trasher` fills and Empty Trash empties. Only paths inside it count as
    /// the Trash; other folders named ".Trash" and other volumes' ".Trashes" don't.
    let trashFolder: URL
    /// The listing and parent checks Empty Trash makes; tests make them fail or act in between.
    @ObservationIgnored private let trashWalk: TrashWalk

    init(
        clipboard: FileClipboard = .shared,
        copier: @escaping Copier = { try FileCopier.copy(from: $0, to: $1, progress: $2, shouldCancel: $3) },
        measureSizes: @escaping SizeMeasurer = { await FileActions.sizes(of: $0) },
        trashFolder: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash"),
        trasher: @escaping Trasher = FileActions.systemTrasher,
        trashWalk: TrashWalk = .system
    ) {
        self.clipboard = clipboard
        self.copier = copier
        self.measureSizes = measureSizes
        self.trashFolder = trashFolder.canonical
        self.trasher = trasher
        self.trashWalk = trashWalk
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

    /// Drops the undo steps that need items in the Trash, once emptying it deleted them; every
    /// other undo step (renames, moves, copies elsewhere…) stays.
    func dropTrashUndo() {
        undoManager?.removeAllActions(withTarget: trashUndoTarget)
    }

    /// Permanently deletes everything in `trash`. Not undoable, so callers must ask first.
    /// Refuses anything but `trashFolder`, and it only when it is a real folder: a link named
    /// ".Trash" would otherwise empty the folder it points to. Afterwards the undo steps that
    /// need items in the Trash are dropped, unless emptying stopped before deleting anything
    /// (then those items are all still there).
    func emptyTrash(_ trash: URL) async throws {
        guard trash.canonical == trashFolder else { throw FileActionError.notTheTrash }
        // Checked inside the queued work, right before deleting: the Trash may change while
        // earlier operations run.
        try await serialized {
            let result = await Self.performEmptyTrash(trash, walk: self.trashWalk)
            // A Trash already empty (emptied in Finder) also leaves those steps nothing to restore.
            if result.deletedSomething || result.error == nil { self.dropTrashUndo() }
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

    /// What emptying did so far: whether anything at all was deleted, and the first failure.
    private nonisolated struct Deletion {
        var deletedSomething = false
        var error: (any Error)?

        mutating func fail(_ code: Int32, path: String) {
            guard code != ENOENT else { return }   // already gone
            error = error ?? FileActions.removalError(code, path: path)
        }
    }

    /// Deletes the Trash's contents relative to the folder opened once (never through a link):
    /// a link swapped in for the Trash, or for a folder inside it, is never followed. Goes on
    /// past items it can't delete, and stops when the Trash's path no longer leads to it.
    @concurrent private nonisolated static func performEmptyTrash(
        _ trash: URL, walk: TrashWalk
    ) async -> (deletedSomething: Bool, error: (any Error)?) {
        guard let identity = realFolderIdentity(trash) else { return (false, FileActionError.notTheTrash) }
        let folder = open(trash.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else {
            let code = errno
            return (false, code == ELOOP || code == ENOTDIR ? FileActionError.notTheTrash : removalError(code, path: trash.path))
        }
        defer { close(folder) }
        guard let opened = FolderIdentity(of: folder), opened == FolderIdentity(identity) else {
            return (false, FileActionError.notTheTrash)
        }
        let names: [[CChar]]
        switch walk.listEntries(folder) {
        case .success(let found): names = found
        case .failure(let failure): return (false, removalError(failure.code, path: trash.path))
        }
        var deletion = Deletion()
        for name in names {
            // Still the same real folder at the Trash's path, never a link swapped in.
            guard let current = realFolderIdentity(trash), current == identity else {
                return (deletion.deletedSomething, FileActionError.notTheTrash)
            }
            remove(name, inTrash: folder, identity: opened, path: trash.path + "/" + displayName(name), walk: walk, &deletion)
        }
        return (deletion.deletedSomething, deletion.error)
    }

    /// A folder's device and inode.
    nonisolated struct FolderIdentity: Equatable, Sendable {
        let device: dev_t, inode: ino_t

        init(_ identity: (dev_t, ino_t)) { (device, inode) = identity }

        init?(of descriptor: Int32) {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            (device, inode) = (info.st_dev, info.st_ino)
        }

        /// The folder at `child`, relative to the open folder; a final link isn't followed.
        init?(of descriptor: Int32, child: UnsafePointer<CChar>) {
            var info = stat()
            guard fstatat(descriptor, child, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            (device, inode) = (info.st_dev, info.st_ino)
        }

        /// The identity of the open folder's parent (".."), or why it can't be read.
        static func parent(of descriptor: Int32) -> Result<FolderIdentity, SystemCallError> {
            var info = stat()
            guard fstatat(descriptor, "..", &info, AT_SYMLINK_NOFOLLOW) == 0 else { return .failure(SystemCallError(code: errno)) }
            guard info.st_mode & S_IFMT == S_IFDIR else { return .failure(SystemCallError(code: ENOTDIR)) }
            return .success(FolderIdentity((info.st_dev, info.st_ino)))
        }
    }

    /// The calls Empty Trash's walk makes besides deleting: listing an open folder and reading
    /// its parent's identity.
    nonisolated struct TrashWalk: Sendable {
        var listEntries: @Sendable (_ folder: Int32) -> Result<[[CChar]], SystemCallError>
        var parentOf: @Sendable (_ folder: Int32) -> Result<FolderIdentity, SystemCallError>

        static let system = TrashWalk(listEntries: FileActions.entryNames(of:), parentOf: FolderIdentity.parent(of:))
    }

    /// Deletes the Trash's top-level entry `name`; a folder's contents first. Links are deleted,
    /// never followed. Walks with an explicit stack and keeps only the folder it works in open,
    /// going down by name and back up through "..", each checked to be the expected folder.
    /// Before every deletion the folder must still be in its parent: one moved meanwhile (out of
    /// the Trash, say) stops being emptied; a folder whose ancestor was moved, within 64 steps.
    /// A top-level folder renamed inside the Trash is still in it, so it keeps being emptied.
    private nonisolated static func remove(
        _ name: [CChar], inTrash trash: Int32, identity trashIdentity: FolderIdentity, path: String,
        walk: TrashWalk, _ deletion: inout Deletion
    ) {
        struct Folder {
            let identity: FolderIdentity, name: [CChar]
            let entries: [[CChar]]
            var next = 0
        }
        var chain: [Folder] = []        // from the top-level folder down to the one worked in
        var current: Int32 = -1         // the descriptor of chain.last
        var steps = 0                   // walk steps below the top-level folder, to space the ancestor checks
        defer { if current >= 0 { close(current) } }

        func parentIdentity(of index: Int) -> FolderIdentity { index == 0 ? trashIdentity : chain[index - 1].identity }
        // Built only for an error message: building it for every item would cost the depth.
        func pathOf(_ name: [CChar]?, depth: Int) -> String {
            ([path] + chain.prefix(depth).dropFirst().map { displayName($0.name) } + [name.map(displayName)].compactMap { $0 })
                .joined(separator: "/")
        }
        // Whether every folder above chain[index] is still in its recorded parent, up to the
        // Trash (chain[index]'s own parent is checked by the caller). Climbs one folder at a time
        // through ".." (never a link), so any depth is checked with two descriptors open.
        enum Ancestors { case inPlace, moved(Int), failed(Int32, Int) }
        func checkAncestors(of index: Int) -> Ancestors {
            var folder = current, owned = false
            defer { if owned { close(folder) } }
            for level in stride(from: index - 1, through: 0, by: -1) {
                let up = openat(folder, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                // It is open, so "gone" can't be taken as already deleted: report it.
                guard up >= 0 else { return .failed(errno == ENOENT ? EIO : errno, level + 1) }
                if owned { close(folder) }
                (folder, owned) = (up, true)
                // chain[level + 1]'s parent isn't chain[level]: it was moved.
                guard FolderIdentity(of: folder) == chain[level].identity else { return .moved(level + 1) }
                switch walk.parentOf(folder) {
                case .failure(let failure): return .failed(failure.code == ENOENT ? EIO : failure.code, level)
                case .success(let found) where found != parentIdentity(of: level): return .moved(level)
                case .success: continue
                }
            }
            return .inPlace
        }
        // Stops emptying this entry when an ancestor moved or can't be read; whether it stopped.
        func stopUnlessInPlace(_ ancestors: Ancestors) -> Bool {
            switch ancestors {
            case .inPlace: return false
            case .moved(let index): stopMoved(index)
            case .failed(let code, let index):
                deletion.fail(code, path: pathOf(nil, depth: index + 1))
                chain.removeAll()
            }
            return true
        }
        // Stops emptying this entry: chain[index] (the folder worked in by default) was moved.
        func stopMoved(_ index: Int? = nil) {
            let moved = index.map { chain[$0].name } ?? chain.last?.name ?? name
            deletion.error = deletion.error ?? FileActionError.movedWhileEmptying(displayName(moved))
            chain.removeAll()
        }
        // Deletes anything but a folder at once; enters a folder so its entries go first.
        func visit(_ name: [CChar]) {
            let parent = current >= 0 ? current : trash
            let itemPath = { chain.isEmpty ? path : pathOf(name, depth: chain.count) }
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return deletion.fail(errno, path: itemPath()) }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                if unlinkat(parent, name, 0) == 0 { deletion.deletedSomething = true } else { deletion.fail(errno, path: itemPath()) }
                return
            }
            let folder = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard folder >= 0 else { return deletion.fail(errno, path: itemPath()) }
            guard let identity = FolderIdentity(of: folder) else {
                close(folder)
                return deletion.fail(EIO, path: itemPath())
            }
            let entries: [[CChar]]
            switch walk.listEntries(folder) {
            case .success(let found): entries = found
            case .failure(let failure):
                entries = []
                deletion.fail(failure.code, path: itemPath())
            }
            // Its ".." must be readable to check, before every deletion, that it wasn't moved. If
            // it isn't (no search permission, say), don't enter it: an empty one can still go; a
            // full one stays, with that failure (for no permission, on its first entry, which is
            // what can't be reached).
            if case .failure(let failure) = walk.parentOf(folder) {
                close(folder)
                if let first = entries.first {
                    let path = failure.code == EACCES ? itemPath() + "/" + displayName(first) : itemPath()
                    // It is open, so "gone" can't be taken as already deleted: report it.
                    return deletion.fail(failure.code == ENOENT ? EIO : failure.code, path: path)
                }
                if unlinkat(parent, name, AT_REMOVEDIR) == 0 { deletion.deletedSomething = true } else { deletion.fail(errno, path: itemPath()) }
                return
            }
            if current >= 0 { close(current) }
            current = folder
            chain.append(Folder(identity: identity, name: name, entries: entries))
        }

        visit(name)
        while let last = chain.indices.last {
            // Still in the same parent: moving it out of the Trash changes its parent. A parent
            // that can't be read is reported as itself, never as a move.
            switch walk.parentOf(current) {
            case .failure(let failure):
                deletion.fail(failure.code == ENOENT ? EIO : failure.code, path: pathOf(nil, depth: last + 1))
                chain.removeAll()
                continue
            case .success(let found) where found != parentIdentity(of: last):
                stopMoved()
                continue
            case .success:
                break
            }
            // An ancestor moved out takes this folder along without changing its parent: check
            // the top-level folder before every deletion, and every ancestor every 64 steps
            // (an item deleted or a folder entered), so the climbs cost the depth once per 64.
            if last > 0 {
                var top = stat()
                if fstatat(trash, chain[0].name, &top, AT_SYMLINK_NOFOLLOW) != 0 {
                    let code = errno
                    if code != ENOENT {
                        // Can't be read: report that, not a move.
                        deletion.fail(code, path: path)
                        chain.removeAll()
                        continue
                    }
                    // Its name is gone: renamed in the Trash (or being deleted) is fine; climb
                    // to see whether it is still in the Trash.
                    if stopUnlessInPlace(checkAncestors(of: last)) { continue }
                } else if FolderIdentity(of: trash, child: chain[0].name) != chain[0].identity {
                    // Another item took its name: it was moved away.
                    stopMoved(0)
                    continue
                } else if steps % 64 == 0, stopUnlessInPlace(checkAncestors(of: last)) {
                    continue
                }
            }
            steps += 1
            if chain[last].next < chain[last].entries.count {
                let child = chain[last].entries[chain[last].next]
                chain[last].next += 1
                visit(child)
                continue
            }
            // Done with its entries: go back up to its parent and delete it there.
            let parent: Int32
            if last == 0 {
                parent = trash
            } else {
                parent = openat(current, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard parent >= 0, FolderIdentity(of: parent) == chain[last - 1].identity else {
                    if parent >= 0 { close(parent) }
                    stopMoved()
                    continue
                }
            }
            close(current)
            current = last == 0 ? -1 : parent
            if unlinkat(parent, chain[last].name, AT_REMOVEDIR) == 0 {
                deletion.deletedSomething = true
            } else {
                let code = errno
                // Not empty because something inside couldn't go: that failure is already recorded.
                if code != ENOTEMPTY || deletion.error == nil { deletion.fail(code, path: pathOf(nil, depth: last + 1)) }
            }
            chain.removeLast()
        }
    }

    /// The raw names in an open folder (raw, so any name still matches), or the error that
    /// stopped the listing: a read error never passes for the end of the folder.
    nonisolated static func entryNames(of folder: Int32) -> Result<[[CChar]], SystemCallError> {
        let copy = dup(folder)
        guard copy >= 0 else { return .failure(SystemCallError(code: errno)) }
        guard let directory = fdopendir(copy) else {
            let code = errno
            close(copy)
            return .failure(SystemCallError(code: code))
        }
        defer { closedir(directory) }
        var names: [[CChar]] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                let code = errno
                return code == 0 ? .success(names) : .failure(SystemCallError(code: code))
            }
            let length = Int(entry.pointee.d_namlen)
            var name = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.bindMemory(to: CChar.self).prefix(length)) }
            if name == [46] || name == [46, 46] { continue }   // "." and ".."
            name.append(0)
            names.append(name)
        }
    }

    /// A failed system call's error code.
    nonisolated struct SystemCallError: Error, Sendable { let code: Int32 }

    private nonisolated static func displayName(_ name: [CChar]) -> String {
        String(decoding: name.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Like `FileManager.removeItem`'s errors: "“name” couldn't be removed because…".
    private nonisolated static func removalError(_ code: Int32, path: String) -> any Error {
        let kind: CocoaError.Code = code == EPERM || code == EACCES ? .fileWriteNoPermission : .fileWriteUnknown
        return CocoaError(kind, userInfo: [
            NSFilePathErrorKey: path,
            "NSUserStringVariant": ["Remove"],
            NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) as NSError,
        ])
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
        // Undo moves items from where they went, redo from where they were: each needs the
        // Trash when those places are in it (a trip into the Trash, a move out, a rename in it).
        let needsTrash = (
            undo: done.contains { self.isInTrash($0.to) },
            redo: done.contains { self.isInTrash($0.from) })
        registerRelocationUndo(actionName, RelocationRecord(transfers: done), needsTrash: needsTrash)
    }

    /// Whether `url` is inside `trashFolder`, the Trash that Empty Trash empties; another
    /// folder named ".Trash" or another volume's `.Trashes` isn't emptied, so its steps keep working.
    /// Compared by folder identity, so a path spelled through a link or in other letter case
    /// counts too.
    private func isInTrash(_ url: URL) -> Bool {
        if url.canonical.path.hasPrefix(trashFolder.path + "/") { return true }
        var trash = stat()
        guard stat(trashFolder.path, &trash) == 0 else { return false }
        // The parent with its links resolved, then each of its folders up to the root.
        var folder = url.deletingLastPathComponent().resolvingSymlinksInPath()
        while true {
            var info = stat()
            if stat(folder.path, &info) == 0, info.st_dev == trash.st_dev, info.st_ino == trash.st_ino { return true }
            if folder.pathComponents.count <= 1 { return false }   // the root
            folder = folder.deletingLastPathComponent()
        }
    }

    /// Undo and redo hand each other a record of what their disk work really moved, so a step
    /// that stopped partway is reversed only as far as it got. `needsTrash.undo` says whether
    /// this entry moves items out of the Trash (emptying it breaks the entry, see
    /// `dropTrashUndo`); `needsTrash.redo`, the same for the entry it registers in turn.
    private func registerRelocationUndo(
        _ actionName: String, _ record: RelocationRecord, needsTrash: (undo: Bool, redo: Bool)
    ) {
        registerUndo(actionName, target: needsTrash.undo ? trashUndoTarget : self) { actions in
            let trasher = actions.trasher
            let reverse = RelocationRecord(transfers: [])
            actions.registerRelocationUndo(actionName, reverse, needsTrash: (undo: needsTrash.redo, redo: needsTrash.undo))
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
        // Copies made in the Trash are gone once it is emptied.
        let intoTrash = record.transfers.contains { self.isInTrash($0.to) }
        registerUndo("Copy", target: intoTrash ? trashUndoTarget : self) { actions in
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
        registerUndo(actionName, target: isInTrash(url) ? trashUndoTarget : self) { actions in
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
