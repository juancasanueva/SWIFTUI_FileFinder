import AppKit

/// Finder-compatible file clipboard: file URLs on an `NSPasteboard`.
///
/// "Cut" is not a pasteboard concept on macOS (Finder uses Copy + ⌥⌘V), so the cut intent is
/// remembered locally and only honored while the pasteboard still holds what we wrote.
final class FileClipboard {
    /// Shared by every window so a cut in one window pastes as a move in another.
    static let shared = FileClipboard()

    private let pasteboard: NSPasteboard
    private var cutChangeCount: Int?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func write(_ urls: [URL], cut: Bool) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        cutChangeCount = cut ? pasteboard.changeCount : nil
    }

    func read() -> (urls: [URL], isCut: Bool) {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return (urls, cutChangeCount == pasteboard.changeCount)
    }

    var hasFiles: Bool { !read().urls.isEmpty }
}
