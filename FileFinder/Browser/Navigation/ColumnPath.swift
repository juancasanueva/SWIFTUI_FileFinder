import Foundation

/// Which folders column view shows: from the folder where browsing started (the root) down to
/// the current folder, like Finder's columns.
nonisolated enum ColumnPath {
    /// `root`, each folder below it on the way, and `current`; just `current` when it isn't
    /// inside `root`.
    static func folders(root: URL, current: URL) -> [URL] {
        guard contains(root, current) else { return [current] }
        let rootParts = root.pathComponents
        let parts = current.pathComponents
        return (rootParts.count...parts.count).map { count in
            let path = NSString.path(withComponents: Array(parts.prefix(count)))
            return URL(filePath: path, directoryHint: .notDirectory)
        }
    }

    /// The root after moving to `current`: kept while `current` is inside it, otherwise
    /// browsing starts again from `current`.
    static func root(keeping root: URL, current: URL) -> URL {
        contains(root, current) ? root : current
    }

    private static func contains(_ root: URL, _ url: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }
}
