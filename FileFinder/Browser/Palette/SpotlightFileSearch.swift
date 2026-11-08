import Foundation

/// Searches file and folder names across the Mac with the Spotlight index.
/// Spotlight leaves out what it doesn't index, such as hidden files and node_modules.
final class SpotlightFileSearch: FileSearching {
    /// Results read from Spotlight, at most; they come most recently used first.
    private let limit: Int
    /// Waits this long for Spotlight to finish, then uses what it found so far.
    private let timeout: Duration

    init(limit: Int = 200, timeout: Duration = .seconds(1.5)) {
        self.limit = limit
        self.timeout = timeout
    }

    func search(_ query: String) async -> [PaletteFile] {
        guard let predicate = Self.predicate(for: query) else { return [] }
        let metadataQuery = NSMetadataQuery()
        metadataQuery.predicate = predicate
        metadataQuery.searchScopes = [NSMetadataQueryLocalComputerScope]
        metadataQuery.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        guard metadataQuery.start() else { return [] }
        defer { metadataQuery.stop() }

        // The query gathers on the main run loop, which keeps running while this task sleeps.
        let deadline = ContinuousClock.now + timeout
        while metadataQuery.isGathering, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard !Task.isCancelled else { return [] }

        metadataQuery.disableUpdates()
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        let found = (0..<min(metadataQuery.resultCount, limit)).compactMap { index -> PaletteFile? in
            guard let item = metadataQuery.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { return nil }
            let types = item.value(forAttribute: "kMDItemContentTypeTree") as? [String] ?? []
            return PaletteFile(url: URL(filePath: path), isDirectory: types.contains("public.folder"))
        }
        // Your own files before the system's.
        return found.filter { $0.url.path.hasPrefix(home) } + found.filter { !$0.url.path.hasPrefix(home) }
    }

    /// Every word of the query must be part of the name, ignoring case and accents.
    static func predicate(for query: String) -> NSPredicate? {
        let parts = query.split(whereSeparator: \.isWhitespace).map { word in
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(escaped(String(word)))*")
        }
        // NSMetadataQuery throws on an AND with a single part.
        guard parts.count > 1 else { return parts.first }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    /// `*` and `?` are wildcards in LIKE; typed ones match themselves.
    private static func escaped(_ word: String) -> String {
        word.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
    }
}
