import Foundation

/// Parsing, Tab-completion and breadcrumbs for the path bar (⌘L).
nonisolated enum PathInput {
    /// Resolves typed text to an existing folder, or `nil`.
    static func resolve(_ text: String, relativeTo base: URL) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = absoluteURL(for: trimmed, relativeTo: base)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    /// Completes the last path component against existing folders, like a shell's Tab.
    static func complete(_ text: String, relativeTo base: URL) -> String {
        let slash = text.lastIndex(of: "/")
        let parentText = slash.map { String(text[...$0]) } ?? ""
        let partial = slash.map { String(text[text.index(after: $0)...]) } ?? text
        guard !partial.isEmpty else { return text }

        let parent = parentText.isEmpty ? base : absoluteURL(for: parentText, relativeTo: base)
        let showHidden = partial.hasPrefix(".")
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let matches = ((try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: options)) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { $0.lowercased().hasPrefix(partial.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        switch matches.count {
        case 0:
            return text
        case 1:
            return parentText + matches[0] + "/"
        default:
            let common = longestCommonPrefix(matches)
            return common.count > partial.count ? parentText + common : text
        }
    }

    /// Every folder from the volume root down to `url`, root first.
    static func breadcrumbs(for url: URL) -> [URL] {
        var crumbs: [URL] = []
        var current = url.canonical
        while true {
            crumbs.append(current)
            if current.path == "/" || current.pathComponents.count <= 1 { break }
            current = current.deletingLastPathComponent()
        }
        return crumbs.reversed()
    }

    private static func absoluteURL(for text: String, relativeTo base: URL) -> URL {
        let expanded = (text as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(filePath: expanded, directoryHint: .isDirectory)
            : base.appending(path: expanded, directoryHint: .isDirectory)
        return url.standardizedFileURL
    }

    private static func longestCommonPrefix(_ names: [String]) -> String {
        guard var prefix = names.first else { return "" }
        for name in names.dropFirst() {
            while !name.lowercased().hasPrefix(prefix.lowercased()) { prefix.removeLast() }
        }
        return prefix
    }
}
