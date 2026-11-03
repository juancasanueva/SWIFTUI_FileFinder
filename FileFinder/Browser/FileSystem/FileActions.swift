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

/// Mutating file operations. Every successful operation registers its inverse on `undoManager`.
@Observable
final class FileActions {
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored let clipboard: FileClipboard

    private var fileManager: FileManager { .default }

    init(clipboard: FileClipboard = .shared) {
        self.clipboard = clipboard
    }

    // MARK: - Rename

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
        registerUndo("Rename") { _ = try? $0.rename(destination, to: oldName) }
        return destination
    }

    // MARK: - Copy / Move

    /// Copies items into `folder`, keeping both on name clashes. Returns the created URLs.
    @discardableResult
    func copy(_ urls: [URL], into folder: URL) throws -> [URL] {
        try Self.rejectNesting(urls, into: folder)
        var created: [URL] = []
        defer {
            if !created.isEmpty {
                let copies = created
                registerUndo("Copy") { $0.trashSilently(copies) }
            }
        }
        for source in urls {
            let copyStyle = Self.isSameFolder(source.deletingLastPathComponent(), folder)
            let destination = Self.uniqueDestination(for: source, in: folder, copyStyle: copyStyle)
            do {
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                // Don't leave a half-copied item behind.
                if fileManager.fileExists(atPath: destination.path) { trashSilently([destination]) }
                throw error
            }
            created.append(destination)
        }
        return created
    }

    /// Moves items into `folder`. Items already in `folder` are skipped. Returns the new URLs.
    @discardableResult
    func move(_ urls: [URL], into folder: URL) throws -> [URL] {
        try Self.rejectNesting(urls, into: folder)
        let pairs = urls
            .filter { !Self.isSameFolder($0.deletingLastPathComponent(), folder) }
            .map { (from: $0, to: Self.uniqueDestination(for: $0, in: folder, copyStyle: false)) }
        try relocate(pairs, actionName: "Move")
        return pairs.map(\.to)
    }

    // MARK: - Trash

    func trash(_ urls: [URL]) throws {
        var pairs: [(from: URL, to: URL)] = []
        defer {
            if !pairs.isEmpty {
                let restore = pairs.map { (from: $0.to, to: $0.from) }
                registerUndo("Move to Trash") { try? $0.relocate(restore, actionName: "Move to Trash") }
            }
        }
        for url in urls {
            var resulting: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &resulting)
            if let trashed = resulting as URL? { pairs.append((url, trashed)) }
        }
    }

    // MARK: - Clipboard

    func copyToClipboard(_ urls: [URL]) { clipboard.write(urls, cut: false) }
    func cutToClipboard(_ urls: [URL]) { clipboard.write(urls, cut: true) }
    var canPaste: Bool { clipboard.hasFiles }

    /// Pastes clipboard files into `folder`: moves after a cut (or when `forceMove`, Finder's ⌥⌘V),
    /// copies otherwise.
    @discardableResult
    func paste(into folder: URL, forceMove: Bool = false) throws -> [URL] {
        let (urls, isCut) = clipboard.read()
        guard !urls.isEmpty else { return [] }
        guard isCut || forceMove else { return try copy(urls, into: folder) }
        let moved = try move(urls, into: folder)
        if !moved.isEmpty { clipboard.write(moved, cut: false) }
        return moved
    }

    // MARK: - Helpers

    private func relocate(_ pairs: [(from: URL, to: URL)], actionName: String) throws {
        var done: [(from: URL, to: URL)] = []
        defer {
            if !done.isEmpty {
                let inverse = done.reversed().map { (from: $0.to, to: $0.from) }
                registerUndo(actionName) { try? $0.relocate(inverse, actionName: actionName) }
            }
        }
        for pair in pairs {
            try fileManager.moveItem(at: pair.from, to: pair.to)
            done.append(pair)
        }
    }

    private func trashSilently(_ urls: [URL]) {
        for url in urls { try? fileManager.trashItem(at: url, resultingItemURL: nil) }
    }

    private func registerUndo(_ actionName: String, _ handler: @escaping (FileActions) -> Void) {
        guard let undoManager else { return }
        // Registrations made while undoing/redoing are grouped by the undo manager itself.
        let needsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { handler($0) }
        undoManager.setActionName(actionName)
        if needsGroup { undoManager.endUndoGrouping() }
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
    nonisolated static func uniqueDestination(for source: URL, in folder: URL, copyStyle: Bool) -> URL {
        let fileManager = FileManager.default
        let name = source.lastPathComponent
        let candidate = folder.appendingPathComponent(name)
        if !copyStyle, !fileManager.fileExists(atPath: candidate.path) { return candidate }

        let ext = source.pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        func named(_ stem: String) -> URL {
            folder.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
        }

        var index = copyStyle ? 1 : 2
        while true {
            let stem = copyStyle
                ? (index == 1 ? "\(base) copy" : "\(base) copy \(index)")
                : "\(base) \(index)"
            let url = named(stem)
            if !fileManager.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }
}
