import Foundation
@testable import FileFinder

/// A throwaway directory under the system temp dir, removed on deinit.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileFinderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func file(_ relativePath: String, bytes: Int = 0) throws -> URL {
        let fileURL = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: fileURL)
        return fileURL
    }

    @discardableResult
    func folder(_ relativePath: String) throws -> URL {
        let folderURL = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }
}

extension FileActions {
    /// FileActions for tests. Move to Trash always fills a throwaway folder (`trashFolder`, or a
    /// fresh one under the system temp dir), never the user's real Trash.
    static func testing(
        clipboard: FileClipboard,
        copier: @escaping Copier = { try FileCopier.copy(from: $0, to: $1, progress: $2, shouldCancel: $3) },
        measureSizes: @escaping SizeMeasurer = { await FileActions.sizes(of: $0) },
        trashFolder: URL? = nil,
        trasher: Trasher? = nil,
        trashWalk: TrashWalk = .system
    ) -> FileActions {
        let trash = trashFolder ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("FileFinderTests-Trash-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return FileActions(
            clipboard: clipboard, copier: copier, measureSizes: measureSizes, trashFolder: trash,
            trasher: trasher ?? { url in
                let destination = FileActions.uniqueDestination(for: url, in: trash, copyStyle: false)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            },
            trashWalk: trashWalk)
    }
}
