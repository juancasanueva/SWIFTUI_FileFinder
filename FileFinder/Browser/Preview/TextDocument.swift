import Foundation

/// A Markdown file open for editing in the preview pane. It never overwrites a file that
/// changed on disk after it was read: Save stops and the user picks Overwrite or Reload, or
/// the edits go to a copy next to it (`saveRecoveryCopy`).
@Observable
final class TextDocument {
    /// Larger files are previewed but not opened for editing.
    static let sizeLimit = 2 * 1024 * 1024

    /// Where edits go when they can't be written next to the file (a read-only folder, a full disk).
    static var defaultRecoveryFolder: URL {
        URL.applicationSupportDirectory.appending(path: "FileFinder/Unsaved Edits", directoryHint: .isDirectory)
    }

    let url: URL
    @ObservationIgnored private let recoveryFolder: URL
    var text: String
    private(set) var savedText: String
    /// The file changed on disk since it was read, and Save stopped.
    private(set) var hasConflict = false
    /// Why the last save or reload failed.
    private(set) var errorMessage: String?
    /// The file as it was read or last saved, to notice a change by someone else.
    @ObservationIgnored private var diskStamp: DiskStamp?

    private nonisolated struct DiskStamp: Equatable {
        let date: Date?
        let size: Int?
    }

    var isDirty: Bool { text != savedText }

    init(url: URL, recoveryFolder: URL = TextDocument.defaultRecoveryFolder) throws {
        self.url = url.canonical
        self.recoveryFolder = recoveryFolder
        let (text, stamp) = try Self.read(url)
        self.text = text
        savedText = text
        diskStamp = stamp
    }

    /// Writes the edits. Returns false, writing nothing, when the file changed on disk since it
    /// was read (`hasConflict`) or the write failed (`errorMessage`).
    @discardableResult
    func save() -> Bool {
        guard isDirty else { return true }
        // Also a conflict when the file is gone: it was moved, renamed or trashed.
        if Self.stamp(of: url) != diskStamp {
            hasConflict = true
            return false
        }
        return write()
    }

    /// Saves over the copy on disk, after a conflict.
    func overwrite() {
        write()
    }

    /// Writes the edits to a new file, "name (unsaved edits).md", when they can't go into the
    /// file itself: next to it, or in the recovery folder when that folder can't be written.
    /// Returns the copy, or nil when neither place could take it.
    func saveRecoveryCopy() -> URL? {
        if let copy = writeCopy(in: url.deletingLastPathComponent()) { return copy }
        try? FileManager.default.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        return writeCopy(in: recoveryFolder)
    }

    private func writeCopy(in folder: URL) -> URL? {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for number in 1...99 {
            let suffix = number == 1 ? " (unsaved edits)" : " (unsaved edits \(number))"
            let copy = folder.appending(path: ext.isEmpty ? stem + suffix : "\(stem)\(suffix).\(ext)")
            guard !FileManager.default.fileExists(atPath: copy.path) else { continue }
            do {
                try Data(text.utf8).write(to: copy, options: .withoutOverwriting)
                return copy
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Drops the edits and reads the file again.
    func reload() {
        do {
            let (text, stamp) = try Self.read(url)
            self.text = text
            savedText = text
            diskStamp = stamp
            hasConflict = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func write() -> Bool {
        do {
            let snapshot = text
            // Through a symlink to the real file, so the link stays a link.
            try snapshot.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
            savedText = snapshot
            diskStamp = Self.stamp(of: url)
            hasConflict = false
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private static func read(_ url: URL) throws -> (String, DiskStamp?) {
        // Checked before reading, so a huge file is never loaded.
        if let size = stamp(of: url)?.size, size > sizeLimit { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: url)
        guard data.count <= sizeLimit else { throw CocoaError(.fileReadTooLarge) }
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return (text, stamp(of: url))
    }

    /// Date and size; nil when the file is gone.
    private static func stamp(of url: URL) -> DiskStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return DiskStamp(
            date: attributes[.modificationDate] as? Date, size: (attributes[.size] as? NSNumber)?.intValue)
    }
}
